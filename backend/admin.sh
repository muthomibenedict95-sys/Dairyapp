#!/bin/bash
cd ~/Ben/Dairy_app/backend
source venv/bin/activate
source .env
python admin.py "$@"
