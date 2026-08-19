# Lua REPL Sample

Lua 5.5.0 REPL over the raw UART (polling console, `lua/` library,
`CONFIG_LUA=y`). Type Lua expressions line by line; the result is printed
after each line.

## Build

```sh
west build --build-dir build-lua-repl --board clip/nrf5340/cpuapp samples/lua_repl
west flash --build-dir build-lua-repl && nrfutil device reset
```

## Usage

Connect to the UART console (`minicom -D /dev/ttyACM0 -b 921600`), wait for
the `> ` prompt, then type Lua:

```
> print("hello")
hello
> 1 + 2
3
```

Backspace editing is supported; the REPL runs on its own 8 KB-stack thread.
