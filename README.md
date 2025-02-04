# bot
- Input: 10 seconds of compressed video
- Output: mouse and keyboard
- Reinforcement Learning with an AI trained to reward "Human-like" behaviour

# Usage
`$ zig run bot.zig` connects to the default vnc port `:5900`. You need to start your VM before this. Using qemu that would be `$ qemu-system-x86_64 [disk_image]`. Use [vncviewer](https://www.realvnc.com/en/connect/download/viewer/) if you want to see the screen.

# Safety
- No internet access.
- Toy environment.
