const std = @import("std");
const raylib = @import("raylib");
const raygui = @import("raygui");

pub fn main() void {
    raylib.InitWindow(800, 800, "hello world!");
    raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    while (!raylib.WindowShouldClose()) {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();

        raylib.ClearBackground(raylib.BLACK);
        raylib.DrawFPS(10, 10);

        if (1 == raygui.GuiButton(.{ .x = 100, .y = 100, .width = 200, .height = 100 }, "press me!")) {
            std.debug.print("pressed\n", .{});
        }
    }
}

// const raylib = @import("raylib");

// pub fn main() void {
//     raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
//     raylib.InitWindow(800, 800, "hello world!");
//     raylib.SetTargetFPS(60);

//     defer raylib.CloseWindow();

//     while (!raylib.WindowShouldClose()) {
//         raylib.BeginDrawing();
//         defer raylib.EndDrawing();

//         raylib.ClearBackground(raylib.BLACK);
//         raylib.DrawFPS(10, 10);

//         raylib.DrawText("hello world!", 100, 100, 20, raylib.YELLOW);
//     }
// }
