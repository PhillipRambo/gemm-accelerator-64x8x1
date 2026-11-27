# ==== CONFIGURABLE VARIABLES ====
VERILATOR       := verilator

TEST_MODULE     := tb_gemm_accelerator

INCLUDE_DIRS    := +incdir+.

FLIST_DIRS		:= flists
FILELIST        := $(TEST_MODULE).flist
FILE_PATH 		:= $(FLIST_DIRS)/$(FILELIST)

VLT_FLAGS       := -O3
VLT_FLAGS       += --trace
VLT_FLAGS	    += --trace-structs

VLT_WAIVE 		:= -Wno-CASEINCOMPLETE
VLT_WAIVE 		+= -Wno-WIDTHTRUNC
VLT_WAIVE 		+= -Wno-WIDTHEXPAND
VLT_WAIVE 		+= -Wno-fatal

QST_FLAGS	    := -voptargs=\"+acc\"
QST_FLAGS	    += -coverage

BIN_DIR			:= bin
OBJ_DIR         := obj_dir

# Derived from $(FILE_PATH)
SRCS := $(shell cat $(FILE_PATH))

# ==== BUILD TARGET ====
all: $(BIN_DIR)/$(TEST_MODULE)

$(BIN_DIR):
	mkdir -p $@

# Rebuild when the filelist, any listed source or any include changes
# (the course version only watched the filelist)
$(BIN_DIR)/$(TEST_MODULE): $(FILE_PATH) $(SRCS) $(wildcard includes/*.svh) | $(BIN_DIR)
	$(VERILATOR) --sv $(SRCS) $(INCLUDE_DIRS) $(VLT_WAIVE) $(VLT_FLAGS) --binary --top-module $(TEST_MODULE) -o $(TEST_MODULE)
	cp $(OBJ_DIR)/$(TEST_MODULE) $(BIN_DIR)/.
	rm -rf $(OBJ_DIR)

# Build (if needed) and run the Verilator simulation
run: $(BIN_DIR)/$(TEST_MODULE)
	./$(BIN_DIR)/$(TEST_MODULE)


questasim.do: $(FILE_PATH)
	@echo 'Generating $@'
	@echo vlib work > $@
	@echo vlog +cover +acc -sv -f $(FILE_PATH) $(INCLUDE_DIRS) >> $@
	@echo vsim $(QST_FLAGS) work.$(TEST_MODULE) >> $@
	@echo add wave -r \/\* >> $@
	@echo run -all >> $@

questasim-run: questasim.do
	@echo 'Running Questasim simulatio w/ Command Line Interface'
	vsim -c -do questasim.do

questasim-run-gui: questasim.do
	@echo 'Running Questasim simulation w/ GUI'
	vsim -gui -do questasim.do

# ==== CLEAN ====
clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR) *.vcd transcript *.do work *.wlf *covhtmlreport *report.txt

.PHONY: all run clean questasim.do questasim-run questasim-run-gui