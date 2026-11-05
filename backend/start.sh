#!/bin/bash
cd ~/Ben/Dairy_app/backend
source venv/bin/activate
source .env
sudo systemctl start mariadb
echo "Phone sync address: http://$(hostname -I | awk '{print $1}'):8000"
uvicorn main:app --host 0.0.0.0 --port 8000
