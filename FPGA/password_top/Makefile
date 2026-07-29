REPO_PATH=../..
include $(REPO_PATH)/resources/common.mk

MODULE_NAME = password_top
SV_FILES = password_top.sv ../../lab_char/char_gen/char_gen.sv ../../lab_char/char_gen/font_rom.sv ../../lab_multiseg/seven_segment4/seven_segment4.sv 
SV_FILES +=	../../lab_sevenseg/seven_segment/seven_segment.sv ../../lab_debounce/debounce/debounce.sv ../../lab_vga/vga_timing/vga_timing.sv
SV_FILES +=  ../password_crack/password_crack.sv  ../write_vga/write_vga.sv  ../../lab_rx/rx_top/rx_top.sv

SIM_PARAMS = WAIT_TIME_US=50 FILENAME=../../background.mem
SYNTH_PARAMS = FILENAME=../../background.mem
