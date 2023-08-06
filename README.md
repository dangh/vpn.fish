# vpn.fish

Run OpenVPN in a container and expose it's connection as a proxy.

## Installation

```sh
fisher install dangh/vpn.fish
```

## Usage

### Using [macpine](https://github.com/beringresearch/macpine)

This is the recommended method as it has smaller memory footprint.

```sh
# macpine is required
brew install macpine

# ready to connect
vpn connect nasa
```

### Using [colima](https://github.com/abiosoft/colima)

colima is more mature and has larger community, but due to the way it work, it consumes more memory.

```sh
# install colima
brew install colima

# set colima as default runner
set -U vpn_container colima

# ready to connect
vpn connect nasa
```

#### Using Docker instead of containerd

containerd is builtin colima so we use it to have less dependencies. But if you had issue with containerd and want to use docker instead, set variable `vpn_runtime` to `docker`.

```sh
# Docker CLI is required if you're not using Docker Desktop
brew install docker

set -U vpn_runtime docker
```

#### Using QEMU on M1 Mac

We leverage [Apple Virtualization Framework](https://developer.apple.com/documentation/virtualization) on Apple Silicon machine, but if you want to use QEMU, set variable `vpn_vm_type` to `qemu`.

```sh
set -U vpn_vm_type qemu
```

## Configuration

Configuration files are put in $HOME/.config/vpn/{profile} directory.

- `config`: OpenVPN profile.
- `passwd`: OpenVPN password in plain text.
- `domains`: List of slow domains when accessing via VPN.
- `tinyproxy.conf`: tinyproxy [config](https://tinyproxy.github.io/#documentation) to override the default config.

```sh
ls -al ~/.config/vpn/nasa
-rw-r--r--@ 1 t  staff  4538 Oct 11  2022 config
-rw-r--r--@ 1 t  staff    33 Jun 20  2022 domains
-rw-r--r--  1 t  staff    10 Oct 11  2022 passwd

cat ~/.config/vpn/nasa/domains
ssm.ap-southeast-1.amazonaws.com
```
