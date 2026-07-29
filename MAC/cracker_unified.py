import itertools
import string
import time
import threading
import queue
import tkinter as tk
from tkinter import messagebox

try:
    import serial
    HAVE_PYSERIAL = True
except ImportError:
    HAVE_PYSERIAL = False

# ------------------------------------------------------------------
# UART CONFIG
# ------------------------------------------------------------------
# TODO: update SERIAL_PORT to match your Mac's device for the Basys3.
# With the board plugged in, run in Terminal:
#   ls /dev/cu.*
# and pick the one that appears/disappears when you plug/unplug the board
# (often something like /dev/cu.usbserial-XXXXXXXX).
SERIAL_PORT = "/dev/cu.usbserial-XXXX"

# Matches the BAUD_RATE parameter in rx.sv (default 19_200).
# If your instantiation overrides BAUD_RATE, change this to match.
BAUD_RATE = 19200

# rx.sv samples a standard 10-bit frame: 1 start + 8 data + 1 stop.
# That's just 8-N-1, so no special parity handling is needed here.
UART_BYTESIZE = 8
UART_PARITY = 'N'
UART_STOPBITS = 1

# Small delay between bytes so the FPGA has time to latch/ack each
# character before the next one arrives. Shrink this if your top-level
# logic acks fast enough; grow it if characters seem to get dropped.
UART_INTER_BYTE_DELAY = 0.01

# ------------------------------------------------------------------
# Cracker config
# ------------------------------------------------------------------
# Numbers-only mode (ASCII/alnum mode removed per request).
CHARACTERS = string.digits
UPDATE_INTERVAL = 0.1
MAX_OUTPUT_LINES = 200
NUM_THREADS = 4


class PasswordCrackerGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("CPU + Basys3 Password Cracker Demo")
        self.root.geometry("600x540")

        self.target_password = ""
        self.attempts = 0
        self.start_time = None
        self.paused_time = 0
        self.pause_start = None
        self.running = False
        self.paused = False

        self.worker_threads = []
        self.attempts_lock = threading.Lock()
        self.message_queue = queue.Queue()
        self.stop_event = threading.Event()
        self.pause_event = threading.Event()

        # ---- Title ----
        self.title_label = tk.Label(
            root, text="CPU + Basys3 Password Cracker Demo", font=("Arial", 16, "bold")
        )
        self.title_label.pack(pady=10)

        # ---- Length selection ----
        self.length_frame = tk.Frame(root)
        self.length_frame.pack(pady=2)
        tk.Label(self.length_frame, text="Password length (numbers only):").grid(row=0, column=0, padx=5)
        self.length_var = tk.IntVar(value=8)
        self.length_spinbox = tk.Spinbox(
            self.length_frame, from_=1, to=10, width=5,
            textvariable=self.length_var, command=self.update_password_label
        )
        self.length_spinbox.grid(row=0, column=1, padx=5)

        # ---- Password entry ----
        # show="" (i.e. not set) means the typed password is visible in
        # plain text, not masked with asterisks.
        self.password_label = tk.Label(root, text="Set 8-digit password (numbers only)")
        self.password_label.pack(pady=(8, 0))
        self.password_entry = tk.Entry(root, width=25)
        self.password_entry.pack(pady=5)

        # ---- Buttons ----
        self.button_frame = tk.Frame(root)
        self.button_frame.pack(pady=10)
        self.start_button = tk.Button(self.button_frame, text="Start Cracking", command=self.start_cracking)
        self.start_button.grid(row=0, column=0, padx=5)
        self.pause_button = tk.Button(self.button_frame, text="Pause", command=self.pause_cracking, state=tk.DISABLED)
        self.pause_button.grid(row=0, column=1, padx=5)
        self.resume_button = tk.Button(self.button_frame, text="Resume", command=self.resume_cracking, state=tk.DISABLED)
        self.resume_button.grid(row=0, column=2, padx=5)
        self.restart_button = tk.Button(self.button_frame, text="Restart", command=self.restart_cracking, state=tk.DISABLED)
        self.restart_button.grid(row=0, column=3, padx=5)

        # ---- Status labels ----
        self.current_guess_label = tk.Label(root, text="Current guess: None", font=("Arial", 12))
        self.current_guess_label.pack(pady=5)
        self.attempts_label = tk.Label(root, text="Attempts: 0", font=("Arial", 12))
        self.attempts_label.pack(pady=5)
        self.time_label = tk.Label(root, text="Time: 0.0000 seconds", font=("Arial", 12))
        self.time_label.pack(pady=5)
        self.uart_status_label = tk.Label(root, text="Basys3 UART: idle", font=("Arial", 11), fg="gray30")
        self.uart_status_label.pack(pady=(0, 5))

        # ---- Output box ----
        self.output_box = tk.Text(root, height=10, width=64)
        self.output_box.pack(pady=10)

        if not HAVE_PYSERIAL:
            self.uart_status_label.config(
                text="Basys3 UART: pyserial not installed (pip install pyserial)", fg="red"
            )

        self.update_password_label()
        self.check_queue()

    # ------------------------------------------------------------
    # UI helpers
    # ------------------------------------------------------------
    def update_password_label(self):
        length = self.length_var.get()
        self.password_label.config(text=f"Set {length}-digit password (numbers only)")

    def get_characters(self):
        return CHARACTERS

    def split_characters_evenly(self, chars, num_threads):
        chunk_size = len(chars) // num_threads
        chunks = []
        for i in range(num_threads):
            start = i * chunk_size
            end = len(chars) if i == num_threads - 1 else (i + 1) * chunk_size
            chunks.append(chars[start:end])
        return chunks

    def validate_password(self, password):
        length = self.length_var.get()
        if len(password) != length:
            return None, f"Password must be exactly {length} digits long."
        allowed = self.get_characters()
        if not all(ch in allowed for ch in password):
            return None, "Password must contain digits only (0-9)."
        return password, None

    # ------------------------------------------------------------
    # UART
    # ------------------------------------------------------------
    def send_to_basys3(self, password):
        """Runs in its own thread. Sends the password to the Basys3 over UART
        so the FPGA starts cracking at (as close to) the same moment as the
        CPU threads."""
        if not HAVE_PYSERIAL:
            self.message_queue.put({
                "type": "uart_status",
                "text": "Basys3 UART: pyserial not installed, skipped send",
                "error": True,
            })
            return
        try:
            with serial.Serial(
                SERIAL_PORT,
                BAUD_RATE,
                bytesize=UART_BYTESIZE,
                parity=UART_PARITY,
                stopbits=UART_STOPBITS,
                timeout=1,
            ) as ser:
                for ch in password:
                    ser.write(ch.encode("ascii"))
                    time.sleep(UART_INTER_BYTE_DELAY)
            self.message_queue.put({
                "type": "uart_status",
                "text": "Basys3 UART: password sent",
                "error": False,
            })
        except serial.SerialException as e:
            self.message_queue.put({
                "type": "uart_status",
                "text": f"Basys3 UART error: {e}",
                "error": True,
            })

    # ------------------------------------------------------------
    # Cracking control
    # ------------------------------------------------------------
    def start_cracking(self):
        password = self.password_entry.get()
        password, error = self.validate_password(password)
        if error:
            messagebox.showerror("Invalid Password", error)
            return

        self.target_password = password
        self.attempts = 0
        self.start_time = time.time()
        self.paused_time = 0
        self.pause_start = None
        self.running = True
        self.paused = False
        self.stop_event.clear()
        self.pause_event.clear()

        self.output_box.delete("1.0", tk.END)
        self.output_box.insert(tk.END, "Starting cracker in worker threads...\n")

        self.start_button.config(state=tk.DISABLED)
        self.pause_button.config(state=tk.NORMAL)
        self.resume_button.config(state=tk.DISABLED)
        self.restart_button.config(state=tk.NORMAL)
        self.password_entry.config(state=tk.DISABLED)
        self.length_spinbox.config(state=tk.DISABLED)

        # Kick off the UART send to the Basys3 at the same moment as the
        # CPU worker threads, so both start cracking together.
        self.uart_status_label.config(text="Basys3 UART: sending...", fg="gray30")
        uart_thread = threading.Thread(target=self.send_to_basys3, args=(password,), daemon=True)
        uart_thread.start()

        self.worker_threads = []
        characters = self.get_characters()
        chunks = self.split_characters_evenly(characters, NUM_THREADS)
        for thread_id, starting_chars in enumerate(chunks, start=1):
            if not starting_chars:
                continue
            thread = threading.Thread(
                target=self.crack_worker,
                args=(thread_id, starting_chars, characters),
                daemon=True,
            )
            self.worker_threads.append(thread)
            thread.start()

        self.output_box.insert(tk.END, f"Started {len(self.worker_threads)} CPU worker threads.\n")

    def crack_worker(self, thread_id, starting_chars, characters):
        length = self.length_var.get()
        last_update_time = time.time()
        for first_char in starting_chars:
            for rest_tuple in itertools.product(characters, repeat=length - 1):
                if self.stop_event.is_set():
                    return
                while self.pause_event.is_set():
                    if self.stop_event.is_set():
                        return
                    time.sleep(0.05)

                guess = first_char + "".join(rest_tuple)

                with self.attempts_lock:
                    self.attempts += 1
                    attempts_snapshot = self.attempts

                current_time = time.time()
                elapsed_time = self.get_elapsed_time()
                if current_time - last_update_time >= UPDATE_INTERVAL:
                    self.message_queue.put({
                        "type": "update",
                        "thread_id": thread_id,
                        "guess": guess,
                        "attempts": attempts_snapshot,
                        "time": elapsed_time,
                    })
                    last_update_time = current_time

                if guess == self.target_password:
                    self.stop_event.set()
                    self.message_queue.put({
                        "type": "found",
                        "thread_id": thread_id,
                        "guess": guess,
                        "attempts": attempts_snapshot,
                        "time": elapsed_time,
                    })
                    return

    def check_queue(self):
        max_messages_per_check = 20
        messages_processed = 0
        try:
            while messages_processed < max_messages_per_check:
                message = self.message_queue.get_nowait()
                messages_processed += 1

                if message["type"] == "update":
                    guess = message["guess"]
                    attempts = message["attempts"]
                    elapsed_time = message["time"]
                    self.current_guess_label.config(text=f"Current guess: {guess}")
                    self.attempts_label.config(text=f"Attempts: {attempts}")
                    self.time_label.config(text=f"Time: {elapsed_time:.4f} seconds")
                    self.output_box.insert(
                        tk.END, f"Thread {message['thread_id']}: Trying {guess}    Attempts: {attempts}\n"
                    )
                    line_count = int(self.output_box.index("end-1c").split(".")[0])
                    if line_count > MAX_OUTPUT_LINES:
                        self.output_box.delete("1.0", "50.0")
                    self.output_box.see(tk.END)

                elif message["type"] == "found":
                    self.running = False
                    self.paused = False
                    guess = message["guess"]
                    attempts = message["attempts"]
                    elapsed_time = message["time"]
                    thread_id = message["thread_id"]
                    self.current_guess_label.config(text=f"Current guess: {guess}")
                    self.attempts_label.config(text=f"Attempts: {attempts}")
                    self.time_label.config(text=f"Time: {elapsed_time:.4f} seconds")
                    self.output_box.insert(tk.END, "\nPassword cracked!\n")
                    self.output_box.insert(tk.END, f"Found by thread: {thread_id}\n")
                    self.output_box.insert(tk.END, f"Correct password: {guess}\n")
                    self.output_box.insert(tk.END, f"Total attempts: {attempts}\n")
                    self.output_box.insert(tk.END, f"Time taken: {elapsed_time:.4f} seconds\n")
                    self.pause_button.config(state=tk.DISABLED)
                    self.resume_button.config(state=tk.DISABLED)
                    self.restart_button.config(state=tk.NORMAL)
                    messagebox.showinfo(
                        "Password Cracked!",
                        f"Correct password: {guess}\n"
                        f"Found by thread: {thread_id}\n"
                        f"Total attempts: {attempts}\n"
                        f"Time taken: {elapsed_time:.4f} seconds",
                    )

                elif message["type"] == "uart_status":
                    color = "red" if message.get("error") else "green"
                    self.uart_status_label.config(text=message["text"], fg=color)
                    self.output_box.insert(tk.END, f"[UART] {message['text']}\n")
                    self.output_box.see(tk.END)

        except queue.Empty:
            pass
        self.root.after(50, self.check_queue)

    def pause_cracking(self):
        if self.running and not self.paused:
            self.paused = True
            self.pause_start = time.time()
            self.pause_event.set()
            self.output_box.insert(tk.END, "\nPaused.\n")
            self.output_box.see(tk.END)
            self.pause_button.config(state=tk.DISABLED)
            self.resume_button.config(state=tk.NORMAL)

    def resume_cracking(self):
        if self.running and self.paused:
            self.paused = False
            if self.pause_start is not None:
                self.paused_time += time.time() - self.pause_start
                self.pause_start = None
            self.pause_event.clear()
            self.output_box.insert(tk.END, "Resumed.\n")
            self.output_box.see(tk.END)
            self.pause_button.config(state=tk.NORMAL)
            self.resume_button.config(state=tk.DISABLED)

    def restart_cracking(self):
        self.stop_event.set()
        self.pause_event.clear()
        self.running = False
        self.paused = False
        self.target_password = ""
        self.attempts = 0
        self.start_time = None
        self.paused_time = 0
        self.pause_start = None

        while not self.message_queue.empty():
            try:
                self.message_queue.get_nowait()
            except queue.Empty:
                break

        self.current_guess_label.config(text="Current guess: None")
        self.attempts_label.config(text="Attempts: 0")
        self.time_label.config(text="Time: 0.0000 seconds")
        self.uart_status_label.config(text="Basys3 UART: idle", fg="gray30")
        self.output_box.delete("1.0", tk.END)
        self.output_box.insert(tk.END, "Restarted.\n")

        self.start_button.config(state=tk.NORMAL)
        self.pause_button.config(state=tk.DISABLED)
        self.resume_button.config(state=tk.DISABLED)
        self.restart_button.config(state=tk.DISABLED)
        self.password_entry.config(state=tk.NORMAL)
        self.password_entry.delete(0, tk.END)
        self.length_spinbox.config(state=tk.NORMAL)
        self.update_password_label()

    def get_elapsed_time(self):
        if self.start_time is None:
            return 0
        if self.paused and self.pause_start is not None:
            return self.pause_start - self.start_time - self.paused_time
        return time.time() - self.start_time - self.paused_time


def main():
    root = tk.Tk()
    app = PasswordCrackerGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
