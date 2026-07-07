#!/usr/bin/env bash

set -e

zig build

host=marvin.lan

ssh $host 'systemctl --user stop sink'

ssh $host 'mkdir -p ~/.local/bin'
ssh $host 'mkdir -p ~/data'
scp zig-out/bin/sink $host:~/.local/bin/

ssh $host 'mkdir -p ~/.config/systemd/user/'
scp marvin/sink.service $host:~/.config/systemd/user/
ssh $host 'systemctl --user enable --now sink'
ssh $host 'systemctl --user restart sink'

# execute on host, one time, sudo required
# sudo ufw allow 4242
# sudo loginctl enable-linger $USER'
