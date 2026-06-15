#!/bin/sh -ex
VERSION=2.9.9

git clone https://github.com/SSSD/sssd --single-branch --branch ${VERSION} --depth 1 sssd.src
cp -r sssd.src/* .
rm -rf sssd.src
