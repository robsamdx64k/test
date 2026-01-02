CCminer Phone Farm Drop-in (Manager Layer)

1) Install:
   sh install.sh

2) Start:
   cd ~/ccminer
   ./start.sh

3) Watchdog (recommended):
   nohup ~/ccminer/manager.sh watchdog >/dev/null 2>&1 &

4) Per-phone overrides (optional):
   nano ~/ccminer/manager.local.conf
   (copy any lines from manager.conf and adjust)
