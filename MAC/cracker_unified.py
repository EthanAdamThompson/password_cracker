import itertools
import string
import time
import threading
import multiprocessing
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
BAUD_RATE = 19200
UART_BYTESIZE = 8
UART_PARITY = 'N'
UART_STOPBITS = 1
UART_INTER_BYTE_DELAY = 0.01

# ------------------------------------------------------------------
# Cracker config
# ------------------------------------------------------------------
CHARACTERS = string.digits
UPDATE_INTERVAL = 0.1
MAX_OUTPUT_LINES = 200
NUM_WORKERS = 4


# ------------------------------------------------------------------
# Worker function — MUST be a plain module-level function, not a class
# method. macOS uses the "spawn" start method for multiprocessing, which
# pickles the target function + args to send to the child process. A
# bound method carrying a reference to `self` (and therefore the Tkinter
# root/widgets) is not picklable and will crash or silently misbehave.
# ------------------------------------------------------------------
def crack_worker_process(thread_id, starting_chars, characters, length,
                          target_password, message_queue, stop_event,
                          pause_event, update_interval):
    # Everything is wrapped in try/except so a crash in this worker shows
    # up as a message in the GUI instead of silently dying with no output
    # (which is what a bare crash looks like from the main process's side).
    try:
        local_attempts = 0
        last_update_time = time.time()

        # Loop order matters here: iterating the *remaining* digits on the
        # outside and this worker's assigned first-digits on the inside
        # means every first-digit this worker owns gets tried within a
        # handful of attempts of each other, instead of fully exhausting
        # one first-digit (10^(length-1) combinations) before ever moving
        # to the next. With the old nesting, a worker assigned first
        # digits {6,7,8,9} could take minutes just to leave "6" — which is
        # exactly why only the very first digit of each worker's chunk
        # (0, 2, 4, 6 for 4 workers) was ever visible in a normal demo run.
        for rest_tuple in itertools.product(characters, repeat=length - 1):
            rest = "".join(rest_tuple)
            for first_char in starting_chars:
                if stop_event.is_set():
                    return

                while pause_event.is_set():
                    if stop_event.is_set():
                        return
                    time.sleep(0.05)

                guess = first_char + rest
                local_attempts += 1

                now = time.time()
                if now - last_update_time >= update_interval:
                    message_queue.put({
                        "type": "update",
                        "thread_id": thread_id,
                        "guess": guess,
                        "attempts": local_attempts,
                    })
                    last_update_time = now

                if guess == target_password:
                    stop_event.set()
                    message_queue.put({
                        "type": "found",
                        "thread_id": thread_id,
                        "guess": guess,
                        "attempts": local_attempts,
                    })
                    return

        # This worker exhausted its share of the keyspace without a match
        # (expected for every worker except the one that finds it).
        message_queue.put({
            "type": "worker_done",
            "thread_id": thread_id,
            "attempts": local_attempts,
        })
    except Exception as e:
        import traceback
        message_queue.put({
            "type": "error",
            "thread_id": thread_id,
            "error": f"{e}\n{traceback.format_exc()}",
        })


class PasswordCrackerGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("CPU + Basys3 Password Cracker Demo")
        # Launch fullscreen for the demo. Escape exits fullscreen (in case
        # you need to get back to the desktop mid-demo without losing state).
        self.is_fullscreen = True
        self.root.attributes("-fullscreen", True)
        self.root.bind("<Escape>", self.toggle_fullscreen)

        self.target_password = ""
        self.start_time = None
        self.paused_time = 0
        self.pause_start = None
        self.running = False
        self.paused = False

        self.worker_processes = []
        # Latest attempts count reported by each worker, keyed by thread_id.
        # Summed for the on-screen total. Only ever touched from the main
        # thread (inside check_queue), so no lock is needed.
        self.thread_attempts = {}

        self.message_queue = multiprocessing.Queue()
        self.stop_event = multiprocessing.Event()
        self.pause_event = multiprocessing.Event()

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

        # ---- Status boxes ----
        tk.Label(root, text="Password being searched for:", font=("Arial", 11)).pack(pady=(5, 0))
        self.target_password_var = tk.StringVar(value="")
        self.target_password_box = tk.Entry(
            root, textvariable=self.target_password_var, width=25,
            justify="center", font=("Arial", 14, "bold"), state="readonly",
            bg="white", fg="black", readonlybackground="white",
            relief="sunken", bd=3, highlightthickness=1, highlightbackground="black",
        )
        self.target_password_box.pack(pady=(0, 5))

        tk.Label(root, text="Currently testing:", font=("Arial", 11)).pack(pady=(5, 0))
        self.current_guess_var = tk.StringVar(value="None")
        self.current_guess_box = tk.Entry(
            root, textvariable=self.current_guess_var, width=25,
            justify="center", font=("Arial", 14, "bold"), state="readonly",
            bg="white", fg="black", readonlybackground="white",
            relief="sunken", bd=3, highlightthickness=1, highlightbackground="black",
        )
        self.current_guess_box.pack(pady=(0, 5))

        self.attempts_label = tk.Label(root, text="Attempts: 0", font=("Arial", 12))
        self.attempts_label.pack(pady=5)
        self.time_label = tk.Label(root, text="Time: 0.0000 seconds", font=("Arial", 12))
        self.time_label.pack(pady=5)
        self.uart_status_label = tk.Label(root, text="Basys3 UART: idle", font=("Arial", 11), fg="gray30")
        self.uart_status_label.pack(pady=(0, 5))

        # ---- Output box ----
        self.output_box = tk.Text(root, height=10, width=64)
        self.output_box.pack(pady=10, fill=tk.BOTH, expand=True)

        if not HAVE_PYSERIAL:
            self.uart_status_label.config(
                text="Basys3 UART: pyserial not installed (pip install pyserial)", fg="red"
            )

        # Tk 8.5 (still the default on some macOS Python installs) has a
        # documented rendering bug where widgets accept clicks at the right
        # coordinates but fail to actually paint. If we're on it, flag it
        # loudly instead of leaving it to look like a code bug.
        if tk.TkVersion < 8.6:
            self.root.title(
                f"CPU + Basys3 Password Cracker Demo  —  WARNING: Tk {tk.TkVersion} detected, "
                f"upgrade Python (python.org) for correct rendering"
            )
            self.output_box.insert(
                tk.END,
                f"WARNING: Tk version {tk.TkVersion} detected. Tk 8.5 has known rendering bugs "
                "(invisible widgets). Install Python from python.org for Tk 8.6+.\n\n"
            )

        self.update_password_label()
        self.check_queue()

    # ------------------------------------------------------------
    # UI helpers
    # ------------------------------------------------------------
    def toggle_fullscreen(self, event=None):
        self.is_fullscreen = not self.is_fullscreen
        self.root.attributes("-fullscreen", self.is_fullscreen)

    def update_password_label(self):
        length = self.length_var.get()
        self.password_label.config(text=f"Set {length}-digit password (numbers only)")

    def get_characters(self):
        return CHARACTERS

    def split_characters_evenly(self, chars, num_workers):
        chunk_size = len(chars) // num_workers
        chunks = []
        for i in range(num_workers):
            start = i * chunk_size
            end = len(chars) if i == num_workers - 1 else (i + 1) * chunk_size
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
    # UART (stays on a thread, not a process — it's I/O bound, needs to
    # touch self.message_queue, and doesn't need a separate CPU core)
    # ------------------------------------------------------------
    def send_to_basys3(self, password):
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
        self.start_time = time.time()
        self.paused_time = 0
        self.pause_start = None
        self.running = True
        self.paused = False
        self.thread_attempts = {}
        self.stop_event.clear()
        self.pause_event.clear()

        self.target_password_var.set(password)

        self.output_box.delete("1.0", tk.END)
        self.output_box.insert(tk.END, "Starting cracker in worker processes...\n")

        self.start_button.config(state=tk.DISABLED)
        self.pause_button.config(state=tk.NORMAL)
        self.resume_button.config(state=tk.DISABLED)
        self.restart_button.config(state=tk.NORMAL)
        self.password_entry.config(state=tk.DISABLED)
        self.length_spinbox.config(state=tk.DISABLED)

        self.uart_status_label.config(text="Basys3 UART: sending...", fg="gray30")
        uart_thread = threading.Thread(target=self.send_to_basys3, args=(password,), daemon=True)
        uart_thread.start()

        self.worker_processes = []
        characters = self.get_characters()
        length = self.length_var.get()
        chunks = self.split_characters_evenly(characters, NUM_WORKERS)
        for thread_id, starting_chars in enumerate(chunks, start=1):
            if not starting_chars:
                continue
            process = multiprocessing.Process(
                target=crack_worker_process,
                args=(thread_id, starting_chars, characters, length,
                      self.target_password, self.message_queue,
                      self.stop_event, self.pause_event, UPDATE_INTERVAL),
                daemon=True,
            )
            self.worker_processes.append(process)
            process.start()

        self.output_box.insert(tk.END, f"Started {len(self.worker_processes)} CPU worker processes (real multi-core).\n")

    def check_queue(self):
        max_messages_per_check = 20
        messages_processed = 0
        try:
            while messages_processed < max_messages_per_check:
                message = self.message_queue.get_nowait()
                messages_processed += 1

                if message["type"] == "update":
                    guess = message["guess"]
                    self.thread_attempts[message["thread_id"]] = message["attempts"]
                    total_attempts = sum(self.thread_attempts.values())
                    elapsed_time = self.get_elapsed_time()
                    self.current_guess_var.set(guess)
                    self.attempts_label.config(text=f"Attempts: {total_attempts}")
                    self.time_label.config(text=f"Time: {elapsed_time:.4f} seconds")
                    self.output_box.insert(
                        tk.END, f"Thread {message['thread_id']}: Trying {guess}    Attempts: {total_attempts}\n"
                    )
                    line_count = int(self.output_box.index("end-1c").split(".")[0])
                    if line_count > MAX_OUTPUT_LINES:
                        self.output_box.delete("1.0", "50.0")
                    self.output_box.see(tk.END)

                elif message["type"] == "found":
                    self.running = False
                    self.paused = False
                    guess = message["guess"]
                    thread_id = message["thread_id"]
                    self.thread_attempts[thread_id] = message["attempts"]
                    total_attempts = sum(self.thread_attempts.values())
                    elapsed_time = self.get_elapsed_time()
                    self.current_guess_var.set(guess)
                    self.attempts_label.config(text=f"Attempts: {total_attempts}")
                    self.time_label.config(text=f"Time: {elapsed_time:.4f} seconds")
                    self.output_box.insert(tk.END, "\nPassword cracked!\n")
                    self.output_box.insert(tk.END, f"Found by worker: {thread_id}\n")
                    self.output_box.insert(tk.END, f"Correct password: {guess}\n")
                    self.output_box.insert(tk.END, f"Total attempts: {total_attempts}\n")
                    self.output_box.insert(tk.END, f"Time taken: {elapsed_time:.4f} seconds\n")
                    self.pause_button.config(state=tk.DISABLED)
                    self.resume_button.config(state=tk.DISABLED)
                    self.restart_button.config(state=tk.NORMAL)
                    messagebox.showinfo(
                        "Password Cracked!",
                        f"Correct password: {guess}\n"
                        f"Found by worker: {thread_id}\n"
                        f"Total attempts: {total_attempts}\n"
                        f"Time taken: {elapsed_time:.4f} seconds",
                    )

                elif message["type"] == "worker_done":
                    self.thread_attempts[message["thread_id"]] = message["attempts"]

                elif message["type"] == "error":
                    self.output_box.insert(
                        tk.END,
                        f"\n[Worker {message['thread_id']} CRASHED]\n{message['error']}\n"
                    )
                    self.output_box.see(tk.END)
                    self.start_button.config(state=tk.NORMAL)
                    self.pause_button.config(state=tk.DISABLED)
                    self.resume_button.config(state=tk.DISABLED)

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
        self.start_time = None
        self.paused_time = 0
        self.pause_start = None
        self.thread_attempts = {}

        while not self.message_queue.empty():
            try:
                self.message_queue.get_nowait()
            except queue.Empty:
                break

        self.target_password_var.set("")
        self.current_guess_var.set("None")
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
    # Explicitly force "spawn" rather than trusting the platform default.
    # macOS has defaulted to spawn since Python 3.8, but some installs
    # (older interpreters, some Anaconda builds) still default to "fork".
    # Forking a process that already has a live Tk/Cocoa GUI running is a
    # well-known way to crash or silently kill the whole app the moment a
    # child process is spawned — which looks exactly like "nothing happens
    # when I hit Start." Forcing spawn here rules that out entirely.
    multiprocessing.set_start_method("spawn", force=True)
    main()
