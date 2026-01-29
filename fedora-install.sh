#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
  echo "This script requires root privileges. Re-running with sudo..."
  sudo "$0" "$@"
  exit
fi

echo "--- Starting Victus Control Installation (Fedora) ---"

# --- 1. Install Dependencies ---
echo "--> Installing required packages..."

# Fedora Package Mapping:
# meson -> meson
# ninja -> ninja-build
# gtk4 -> gtk4-devel (required for building headers)
# git -> git
# dkms -> dkms
# Base development tools (gcc, g++, etc.) -> gcc-c++
packages=(meson ninja-build gtk4-devel git dkms gcc-c++ policycoreutils-python-utils)

echo "Installing build dependencies..."
dnf install -y "${packages[@]}"

# --- Install Kernel Headers ---
# Arch script loops through all kernels. On Fedora, we prioritize the running kernel.
# DKMS needs 'kernel-devel' matching the exact version of the running kernel.
current_kernel=$(uname -r)
echo "--> Detecting kernel headers for running kernel: $current_kernel"

# Try to install the specific kernel-devel package for the running kernel
if dnf install -y "kernel-devel-uname-r == $current_kernel"; then
    echo "Kernel headers installed for $current_kernel."
else
    echo "Warning: Could not strictly match kernel-devel for $current_kernel."
    echo "Attempting to install latest kernel-devel..."
    dnf install -y kernel-devel
fi

# --- 2. Create Users and Groups ---
echo "--> Creating secure users and groups..."

# Ensure the victus group exists
if ! getent group victus > /dev/null; then
    groupadd --system victus
    echo "Group 'victus' created."
else
    echo "Group 'victus' already exists."
fi

# Create the victus-backend group
if ! getent group victus-backend > /dev/null; then
    groupadd --system victus-backend
    echo "Group 'victus-backend' created."
else
    echo "Group 'victus-backend' already exists."
fi

# Create the victus-backend user
if ! id -u victus-backend > /dev/null 2>&1; then
    useradd --system -g victus-backend -s /usr/sbin/nologin victus-backend
    echo "User 'victus-backend' created."
else
    echo "User 'victus-backend' already exists."
fi

# Add victus-backend to the victus group
if ! groups victus-backend | grep -q '\bvictus\b'; then
    usermod -aG victus victus-backend
    echo "User 'victus-backend' added to the 'victus' group."
else
    echo "User 'victus-backend' is already in the 'victus' group."
fi

# Add the user who invoked sudo to the 'victus' group
if [ -n "$SUDO_USER" ]; then
    if ! groups "$SUDO_USER" | grep -q '\bvictus\b'; then
        usermod -aG victus "$SUDO_USER"
        echo "User '$SUDO_USER' added to the 'victus' group."
    else
        echo "User '$SUDO_USER' is already in the 'victus' group."
    fi
else
    echo "Warning: Could not determine the original user. Please add your user to the 'victus' group manually."
fi

# --- 2.5. Configure Sudoers and Scripts ---
echo "--> Installing helper script and configuring sudoers..."
install -m 0755 backend/src/set-fan-speed.sh /usr/bin/set-fan-speed.sh
install -m 0755 backend/src/set-fan-mode.sh /usr/bin/set-fan-mode.sh

# Remove old sudoers file if exists
rm -f /etc/sudoers.d/victus-fan-sudoers
# Install new sudoers file
install -m 0440 victus-control-sudoers /etc/sudoers.d/victus-control-sudoers
echo "Helper script and sudoers file installed."

# --- 3. Install Patched HP-WMI Kernel Module ---
echo "--> Installing patched hp-wmi kernel module..."
wmi_root="wmi-project"
wmi_repo="${wmi_root}/hp-wmi-fan-and-backlight-control"

mkdir -p "${wmi_root}"

if [ -d "${wmi_repo}/.git" ]; then
    echo "Kernel module source directory already exists. Updating repository..."
    git -C "${wmi_repo}" fetch origin master || echo "Fetch failed, continuing..."
    git -C "${wmi_repo}" reset --hard origin/master || echo "Reset failed, continuing..."
else
    git clone https://github.com/Batuhan4/hp-wmi-fan-and-backlight-control.git "${wmi_repo}"
fi

pushd "${wmi_repo}" >/dev/null

module_name="hp-wmi-fan-and-backlight-control"
module_version="0.0.2"

# Remove existing DKMS if present
if dkms status -m "${module_name}" -v "${module_version}" >/dev/null 2>&1; then
    echo "Removing existing DKMS registration..."
    dkms remove "${module_name}/${module_version}" --all || true
fi

echo "Registering DKMS module..."
dkms add .

echo "Building and installing DKMS module for current kernel ($current_kernel)..."
dkms install "${module_name}/${module_version}" -k "$current_kernel"

# Reload module
if lsmod | grep -q "hp_wmi"; then
  rmmod hp_wmi
fi
modprobe hp_wmi
popd >/dev/null
echo "Kernel module installed and loaded."

# --- 4. Build and Install victus-control ---
echo "--> Building and installing the application..."
# Ensure previous build dir is clean or removed if setup fails
rm -rf build
meson setup build --prefix=/usr
ninja -C build
ninja -C build install
echo "Application built and installed."

# --- 5. Enable Backend Service ---
echo "--> Configuring and starting backend service..."

systemd-tmpfiles --create || echo "Warning: tmpfiles creation issue."
systemctl daemon-reload

udevadm control --reload-rules && udevadm trigger || echo "Warning: udev reload issue."

echo "--> Enabling Healthcheck..."
systemctl enable --now victus-healthcheck.service

echo "--> Enabling Backend..."
systemctl enable --now victus-backend.service

# --- SELinux Warning for Fedora ---
if command -v getenforce > /dev/null; then
    selinux_mode=$(getenforce)
    if [ "$selinux_mode" == "Enforcing" ]; then
        echo ""
        echo "WARNING: Your system is running SELinux in Enforcing mode."
        echo "The victus-backend service may be blocked from writing to /sys/ devices or creating sockets."
        echo "If the app does not work, check logs with: journalctl -xeu victus-backend"
        echo "You may need to set SELinux to Permissive temporarily (sudo setenforce 0) or write a policy."
        echo ""
    fi
fi

echo "--- Installation Complete! ---"
echo "Please log out and log back in to apply group changes."