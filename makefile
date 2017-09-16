AS = nasm
ASFLAGS = -f elf64

SRC = calc.s
OBJ = calc.o
BIN = calc

# the implicit rule for linking calls ld through the C compiler; that
# conflicts with our code, as it tries to link against crt1.o.
# So we use an explicit rule instead.
$(BIN): $(OBJ)
	ld -o $(BIN) $(OBJ)

$(OBJ): $(SRC)

debug: ASFLAGS += -g
debug: $(BIN)

.PHONY: clean
clean:
	rm $(OBJ)
