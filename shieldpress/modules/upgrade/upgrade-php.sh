#!/bin/bash
# Retain the legacy entrypoint while using the same conservative update flow.
BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
exec bash "$BASE_DIR/modules/upgrade/service-updates.sh" php
