const Settings = @This();

window_pages: usize = window_pages_default,
verbose: bool = false,
gauge: Gauge = .{},

pub const window_pages_default: usize = 8;
pub const window_pages_min: usize = 1;
pub const window_pages_max: usize = 64;

pub const Gauge = struct {
    percent_warning: f64 = 75,
    percent_error: f64 = 90,

    pub const percent_min: f64 = 0;
    pub const percent_max: f64 = 100;
};
