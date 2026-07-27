#!/bin/sh
set -eu

sudo apt-get -o Acquire::Retries=5 update
sudo apt-get -o Acquire::Retries=5 install -y \
	libsecret-1-dev \
	pkg-config \
	python3-venv \
	unzip
