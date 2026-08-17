#!/bin/bash

BASE_DIR="/opt/shieldpress"
BACKUP_DIR="$BASE_DIR/update-backups"
VERSION_FILE="$BASE_DIR/version.txt"

GIT_REPO="https://github.com/yourrepo/shieldpress.git"

mkdir -p $BACKUP_DIR

CURRENT_VERSION=$(cat $VERSION_FILE)

echo "Current Version: $CURRENT_VERSION"

echo "Creating backup..."

tar -czf $BACKUP_DIR/shieldpress_backup_$(date +%Y%m%d_%H%M).tar.gz $BASE_DIR

echo "Updating from Git..."

cd /opt
rm -rf shieldpress_new

git clone $GIT_REPO shieldpress_new

if [ ! -d "shieldpress_new" ]; then
    echo "Update failed!"
    exit 1
fi

echo "Replacing old version..."

rm -rf $BASE_DIR/*
cp -r shieldpress_new/* $BASE_DIR/
rm -rf shieldpress_new

echo "Update completed!"