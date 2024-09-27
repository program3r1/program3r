#!/usr/bin/env bash
# Автор: Program3r
# Дата: 27 вересня 2025 року

set -e

print_usage(){
cat <<EOF
Використання: sudo mklimdir.sh -m <Каталог монтування> -f <Файлова система> -s <РОЗМІР>

-m каталог
-f тип файлової системи (один із підтримуваних mke2fs)
-s розмір у байтах
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
    command -v "$1" >/dev/null 2>&1 || { echo ">>> Команда $1 не знайдена. Будь ласка, встановіть її." >&2; exit 1; }
}

parse_args(){
    option_handler(){
        case ${opt} in
            m) mountpoint=$( realpath -e "${OPTARG}" );;
            s) size=${OPTARG} ;;
            h) print_usage; exit 0 ;;
            f) mkfs_cmd=mkfs."${OPTARG}" ;;
            \?) echo ">>> Невірний параметр: -$OPTARG" > /dev/stderr; exit 1;;
            \:) echo ">>> Відсутній аргумент для -${OPTARG}" > /dev/stderr; exit 2;;
        esac
    }

    local OPTIND opt
    getopts "m:s:f:h" opt || { echo "Немає переданих аргументів">/dev/stderr;print_usage;exit 3;}
    option_handler 
    while getopts "m:s:f:h" opt; do
         option_handler
    done
    shift $((OPTIND-1))
}

main(){
    if [ $EUID -ne 0 ]; then
        echo ">>> Будь ласка, запустіть скрипт з правами sudo/як root" > /dev/stderr
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

    parse_args "$@"
    quota_fs=/"${mountpoint//\//_}"_"$(date +%s)".quota
    # Використання fallocate для створення файлу
    fallocate -l "${size}" "$quota_fs"
    "$mkfs_cmd" "$quota_fs"
    
    # Збереження оригінального власника, групи та прав доступу
    original_owner=$(stat -c %u:%g "$mountpoint")
    original_permissions=$(stat -c %a "$mountpoint")
    
    mount -o loop,rw,usrquota,grpquota "$quota_fs" "$mountpoint"
    
    chown "$original_owner" "$mountpoint"
    chmod "$original_permissions" "$mountpoint"
    
    echo "$quota_fs" "$mountpoint" ext4 loop 0 0 >> /etc/fstab

    echo ">>> Каталог з квотою успішно створено та змонтовано."
}

main "$@"
