pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;
pub extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
