#!/usr/bin/env bash
# Автор: Serg Kolo
# Дата: 1 червня 2018 року
# Написано для: https://askubuntu.com/q/1043035/295286
# На основі: https://www.linuxquestions.org/questions/linux-server-73/directory-quota-601140/

set -e

log(){
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

print_usage(){
cat <<EOF
Використання: sudo mklimdir.sh -m <Каталог монтування> -f <Файлова система> -s <РОЗМІР> -g <Група>

-m каталог
-f тип файлової системи (один із підтримуваних mke2fs)
-s розмір у байтах
-g назва групи
-h це повідомлення

Коди завершення:
0: Успішно
1: Невірний параметр
2: Відсутній аргумент
3: Немає аргументів
4: Потрібні права root
EOF
} > /dev/stderr

check_command(){
    command -v "$1" >/dev/null 2>&1 || { log ">>> Команда $1 не знайдена. Будь ласка, встановіть її." >&2; exit 1; }
}

parse_args(){
    option_handler(){
        case ${opt} in
            m) mountpoint=$( realpath -e "${OPTARG}" );;
            s) size=${OPTARG} ;;
            g) group=${OPTARG} ;;
            h) print_usage; exit 0 ;;
            f) mkfs_cmd=mkfs."${OPTARG}" ;;
            \?) log ">>> Невірний параметр: -$OPTARG" > /dev/stderr; exit 1;;
            \:) log ">>> Відсутній аргумент для -${OPTARG}" > /dev/stderr; exit 2;;
        esac
    }

    local OPTIND opt
    getopts "m:s:f:g:h" opt || { log "Немає переданих аргументів">/dev/stderr;print_usage;exit 3;}
    option_handler 
    while getopts "m:s:f:g:h" opt; do
         option_handler
    done
    shift $((OPTIND-1))
}

install_samba(){
    check_command apt-get
    log ">>> Встановлення Samba..."
    apt-get update
    apt-get install -y samba
}

create_group_and_directory(){
    log ">>> Створення групи та директорії..."
    groupadd "$group" || log ">>> Група $group вже існує"
    mkdir -p "$mountpoint"
    chgrp "$group" "$mountpoint"
    chmod 0770 "$mountpoint"
}

configure_samba(){
    log ">>> Налаштування Samba..."
    smb_conf="/etc/samba/smb.conf"
    share_name=$(basename "$mountpoint")
    cat <<EOF >> "$smb_conf"

[$share_name]
   path = $mountpoint
   browseable = yes
   read only = no
   valid users = @${group}
EOF
    systemctl restart smbd
}

main(){
    if [ $EUID -ne 0 ]; then
        log ">>> Будь ласка, запустіть скрипт з правами sudo/як root" > /dev/stderr
        exit 4
    fi

    # Перевірка наявності необхідних команд
    check_command dd
    check_command mkfs
    check_command mount
    check_command stat

    local mountpoint=""
    local size=0
    local mkfs_cmd
    local group=""

    parse_args "$@"
    install_samba
    create_group_and_directory
    
    quota_fs=/"${mountpoint//\//_}"_"$(date +%s)".quota
    log ">>> Створення файлу квоти..."
    dd if=/dev/zero of="$quota_fs" count=1 bs="$size"
    log ">>> Створення файлової системи..."
    "$mkfs_cmd" "$quota_fs"
    
    # Збереження оригінального власника, групи та прав доступу
    original_owner=$(stat -c %u:%g "$mountpoint")
    original_permissions=$(stat -c %a "$mountpoint")
    
    log ">>> Монтування файлової системи з квотою..."
    mount -o loop,rw,usrquota,grpquota "$quota_fs" "$mountpoint"
    
    chown "$original_owner" "$mountpoint"
    chmod "$original_permissions" "$mountpoint"
    
    log ">>> Додавання запису до /etc/fstab..."
    echo "$quota_fs" "$mountpoint" ext4 loop 0 0 >> /etc/fstab

    configure_samba

    log ">>> Каталог з квотою успішно створено, змонтовано та додано до конфігурації Samba."
}

main "$@"
