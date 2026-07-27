#!/bin/sh
set -eu

sudo apt-get -o Acquire::Retries=5 update
sudo apt-get -o Acquire::Retries=5 install -y \
	dbus-daemon \
	gdb \
	gnome-keyring \
	libsecret-1-0 \
	openssl \
	unzip
