# Technical Decisions

### 1. Most technically challenging part?
umm... getting container healthchecks and dependency startup orders synced properly across Nginx, Flask, and Postgres. 

### 2. Key design decision?
Sticking with Docker Compose and an Nginx reverse proxy instead of spinning up full Kubernetes locally... it keeps local dev super lightweight and runnable with just a single command

### 3. Current limitation?
Telemetry logs and metrics are all sitting on local named Docker volumes... so if the host drive dies, history isn't offloaded anywhere in the cloud yet.

### 4. What to improve with another week?
Write proper Terraform scripts for AWS... configure auto-renewing SSL with Certbot, and hook up Alertmanager notifications so server crashes actually ping me.   

