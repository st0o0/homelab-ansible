# Unattended upgrades
unattended_upgrades_enabled: true
# unattended_upgrades_blacklist:
#   - "docker-ce"
#   - "docker-ce-cli"
#   - "containerd.io"
# unattended_upgrades_skip_reboot_required: false
# unattended_upgrades_auto_reboot: false
# unattended_upgrades_auto_reboot_time: "04:00"

# Swap
# swap_enabled: false
# swap_size: "2G"

# Firewall (extra rules beyond SSH)
# ufw_extra_rules:
#   - { rule: allow, port: 8080, proto: tcp, comment: "Web" }

# Docker
# docker_enabled: true

# Cron
# cron_docker_prune: true
# cron_extra_jobs:
#   - { name: "cleanup-logs", job: "find /var/log -name '*.gz' -mtime +30 -delete", schedule: "0 4 * * 0" }

# Node agent
node_agent_alloy_enabled: true
node_agent_hawser_enabled: true
node_agent_bifrost_enabled: false
