#!/usr/bin/env bash

set -e

log(){
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

print_usage(){
cat <<EOF
Використання: sudo bash mklimdir.sh -m <Каталог монтування> -f <Файлова система> -s <РОЗМІР> -g <Група>

-m каталог
-f тип файлової системи (один із підтримуваних mke2fs)
-s розмір у байтах (або у гігабайтах тоді закінчення GiB)
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
    local OPTIND opt
    while getopts "m:s:f:g:h" opt; do
        case ${opt} in
            m) mountpoint="${OPTARG}" ;;  # Не викликаємо realpath до створення директорії
            s) size=${OPTARG} ;;
            g) group=${OPTARG} ;;
            h) print_usage; exit 0 ;;
            f) mkfs_cmd=mkfs."${OPTARG}" ;;
            \?) log ">>> Невірний параметр: -$OPTARG" > /dev/stderr; exit 1 ;;
            \:) log ">>> Відсутній аргумент для -${OPTARG}" > /dev/stderr; exit 2 ;;
        esac
    done
    shift $((OPTIND-1))

    if [[ -z "$mountpoint" || -z "$size" || -z "$group" || -z "$mkfs_cmd" ]]; then
        log ">>> Усі параметри повинні бути вказані." > /dev/stderr
        print_usage
        exit 2
    fi
}

validate_size(){
    if [[ "$size" =~ ^[0-9]+GiB$ ]]; then
        size_bytes=$(( ${size%GiB} * 1024 * 1024 * 1024 ))
    elif [[ "$size" =~ ^[0-9]+$ ]]; then
        size_bytes=$size
    else
        log ">>> Розмір повинен бути позитивним цілим числом або закінчуватися на GiB." > /dev/stderr
        exit 1
    fi
}

install_expect(){
    check_command apt-get
    log ">>> Встановлення expect..."
    apt-get update && apt-get install -y expect || { log ">>> Не вдалося встановити expect." >&2; exit 1; }
}

install_samba(){
    check_command apt-get
    log ">>> Встановлення Samba..."
    apt-get update && apt-get install -y samba || { log ">>> Не вдалося встановити Samba." >&2; exit 1; }
}

create_group_and_directory(){
    log ">>> Створення групи та директорії..."
    groupadd "$group" || log ">>> Група $group вже існує"

    mkdir -p "$mountpoint"  # Створюємо директорію тут
    mountpoint=$( realpath -e "$mountpoint" )  # Викликаємо realpath після створення

    chgrp "$group" "$mountpoint"
    chmod 0770 "$mountpoint"
}

configure_samba(){
    log ">>> Налаштування Samba..."
    smb_conf="/etc/samba/smb.conf"
    cp "$smb_conf" "$smb_conf.bak" # Резервне копіювання існуючої конфігурації
    share_name=$(basename "$mountpoint")
    {
        echo "[$share_name]"
        echo "   path = $mountpoint"
        echo "   browseable = yes"
        echo "   read only = no"
        echo "   valid users = @$group"
    } >> "$smb_conf"
    systemctl restart smbd || { log ">>> Не вдалося перезапустити Samba." >&2; exit 1; }
}

create_user_smb(){
    log ">>> Створення користувача $1 для Samba..."
    
    expect << EOF
spawn smbpasswd -a "$1"
expect "New SMB password:"
send "$2\r"
expect "Retype new SMB password:"
send "$2\r"
expect eof
EOF
}

create_users(){
    read -p "Скільки користувачів ви хочете створити для групи $group? " user_count
    for ((i = 1; i <= user_count; i++)); do
        read -p "Введіть ім'я користувача $i: " username
        useradd -M -s /sbin/nologin "$username" || log ">>> Не вдалося створити користувача $username."
        read -sp "Введіть пароль для $username: " password
        echo
        echo "$username:$password" | chpasswd
        create_user_smb "$username" "$password" || log ">>> Не вдалося додати користувача $username до Samba."
        usermod -aG "$group" "$username"
        log ">>> Користувач $username успішно створений і доданий до групи $group."
    done
}

main(){
    if [ $EUID -ne 0 ]; then
        log ">>> Будь ласка, запустіть скрипт з правами sudo/як root." > /dev/stderr
        exit 4
    fi

    check_command dd
    check_command mkfs
    check_command mount
    check_command stat

    parse_args "$@"
    validate_size
    install_expect  # Встановлюємо expect перед його використанням
    install_samba
    create_group_and_directory

    quota_fs="/${mountpoint//\//_}_$(date +%s).quota"
    log ">>> Створення файлу квоти..."
    dd if=/dev/zero of="$quota_fs" count=1 bs="$size_bytes" || { log ">>> Не вдалося створити файл квоти." >&2; exit 1; }
    log ">>> Створення файлової системи..."
    "$mkfs_cmd" "$quota_fs"

    original_owner=$(stat -c %u:%g "$mountpoint")
    original_permissions=$(stat -c %a "$mountpoint")

    log ">>> Монтування файлової системи з квотою..."
    mount -o loop,rw,usrquota,grpquota "$quota_fs" "$mountpoint" || { log ">>> Не вдалося змонтувати файлову систему." >&2; exit 1; }

    chown "$original_owner" "$mountpoint"
    chmod "$original_permissions" "$mountpoint"

    log ">>> Додавання запису до /etc/fstab..."
    echo "$quota_fs $mountpoint ext4 loop 0 0" >> /etc/fstab

    configure_samba
    create_users

    log ">>> Каталог з квотою успішно створено, змонтовано та додано до конфігурації Samba."
}

main "$@"
