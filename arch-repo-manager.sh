#!/bin/bash

########
#
# Объединенный менеджер локальных репозиториев Arch Linux
# Управление официальным зеркалом и AUR пакетами
# 
# Основан на sync-arch-mirror.sh (Copyright © 2014-2019 Florian Pritz <bluewind@xinu.at>)
# и расширен функционалом управления AUR репозиторием
#
########

# =============================================================================
# КОНФИГУРАЦИЯ
# =============================================================================

# Директория где хранится локальный репозиторий
target="/home/$USER/arch-mirror-repo"

# Директория для AUR репозитория
aur_target="$target/aur"

# Файлы блокировки
mirror_lock="$target/syncrepo.lck"
aur_lock="$target/syncaur.lck"

# Файл со списком AUR пакетов для сборки
aur_packages_file="$target/aur-packages.list"

# Временная директория для сборки AUR
build_dir="/tmp/aur-build-$$"

# Ограничение пропускной способности для rsync (0 = без ограничений)
bwlimit=0

# Файл mirrorlist
mirrorlist_file="/etc/pacman.d/mirrorlist"

# Определяем архитектуру
arch=$(uname -m)

# Директории репозиториев
aur_repo_dir="$aur_target/os/$arch"
aur_db_name="aur-local.db.tar.gz"
aur_db_path="$aur_repo_dir/$aur_db_name"
aur_state_file="$aur_repo_dir/aur-local.state"

# Глобальные переменные для настроек
force_rebuild=false
quiet=false
auto_clean=true

# =============================================================================
# ЦВЕТА И ИНТЕРФЕЙС
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Функция для цветного вывода
print_colored() {
  local color=$1
  local text=$2
  echo -e "${color}${text}${NC}"
}

# Функция для чтения пользовательского ввода
read_input() {
  local prompt=$1
  local default=$2
  if [[ -n "$default" ]]; then
    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
  else
    read -p "$prompt: " input
    echo "$input"
  fi
}

# Функция для подтверждения
confirm() {
  local prompt=$1
  local response
  while true; do
    read -p "$prompt (y/n): " response
    case $response in
      [Yy]* ) return 0;;
      [Nn]* ) return 1;;
      * ) echo "Пожалуйста, ответьте y или n.";;
    esac
  done
}

# Показываем заголовок
show_header() {
  clear
  print_colored $CYAN "╔══════════════════════════════════════════════════════════════════════════╗"
  print_colored $CYAN "║                    Менеджер локальных репозиториев Arch Linux            ║"
  print_colored $CYAN "║                        Зеркало + AUR репозиторий                         ║"
  print_colored $CYAN "╚══════════════════════════════════════════════════════════════════════════╝"
  echo ""
}

# =============================================================================
# ОБЩИЕ ФУНКЦИИ
# =============================================================================

# Создаем необходимые директории
setup_directories() {
  [ ! -d "$target" ] && mkdir -p "$target"
  [ ! -d "$aur_repo_dir" ] && mkdir -p "$aur_repo_dir"
  [ ! -f "$aur_packages_file" ] && touch "$aur_packages_file"
}

# Проверяем наличие необходимых утилит
check_dependencies() {
  local missing=()
  
  if ! command -v rsync >/dev/null 2>&1; then
    missing+=("rsync")
  fi
  
  if ! command -v repo-add >/dev/null 2>&1; then
    missing+=("pacman-contrib")
  fi
  
  if ! command -v yay >/dev/null 2>&1; then
    missing+=("yay")
  fi
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    print_colored $RED "❌ Отсутствуют необходимые пакеты:"
    printf '   %s\n' "${missing[@]}"
    echo ""
    print_colored $YELLOW "Установите недостающие пакеты для полной функциональности"
    return 1
  fi
  
  return 0
}

# Показываем общий статус
show_status() {
  print_colored $BLUE "📊 Статус репозиториев:"
  echo ""
  
  # Статус зеркала
  print_colored $WHITE "🪞 Официальное зеркало:"
  if [[ -f "$target/lastupdate" ]]; then
    local last_update=$(date -d "@$(cat "$target/lastupdate" 2>/dev/null || echo 0)" 2>/dev/null || echo "неизвестно")
    print_colored $GREEN "  ✅ Синхронизировано: $last_update"
  else
    print_colored $YELLOW "  ⚠️  Не синхронизировано"
  fi
  
  local mirror_size=$(du -sh "$target" 2>/dev/null | cut -f1 || echo "0")
  echo "  💾 Размер зеркала: $mirror_size"
  
  # Статус локальных репозиториев
  local local_repos=0
  for repo in core extra community multilib; do
    local repo_dir="$target/$repo/os/$arch"
    if [[ -d "$repo_dir" ]] && [[ -f "$repo_dir/${repo}-local.db.tar.gz" ]]; then
      ((local_repos++))
    fi
  done
  echo "  📦 Локальных репозиториев: $local_repos/4"
  
  echo ""
  
  # Статус AUR
  print_colored $WHITE "📦 AUR репозиторий:"
  local aur_pkg_count=0
  if [[ -f "$aur_packages_file" ]]; then
    aur_pkg_count=$(grep -c '^[^#]' "$aur_packages_file" 2>/dev/null || echo 0)
  fi
  
  local aur_built_count=0
  if [[ -d "$aur_repo_dir" ]]; then
    aur_built_count=$(find "$aur_repo_dir" -name "*.pkg.tar.zst" -type f | wc -l)
  fi
  
  echo "  📋 Пакетов в списке: $aur_pkg_count"
  echo "  🔨 Собранных пакетов: $aur_built_count"
  
  if [[ -f "$aur_db_path" ]]; then
    print_colored $GREEN "  ✅ База данных: создана"
  else
    print_colored $YELLOW "  ⚠️  База данных: не создана"
  fi
  
  local aur_size=$(du -sh "$aur_repo_dir" 2>/dev/null | cut -f1 || echo "0")
  echo "  💾 Размер AUR репозитория: $aur_size"
  echo ""
}

# =============================================================================
# ФУНКЦИИ ЗЕРКАЛА
# =============================================================================

# Получаем зеркала из mirrorlist
get_mirrors() {
  local mirrors=()
  
  if [[ -f "$mirrorlist_file" ]]; then
    while IFS= read -r line; do
      if [[ "$line" == "Server = "* ]]; then
        local url="${line#Server = }"
        local rsync_url="${url/https:\/\//rsync:\/\/}"
        rsync_url="${rsync_url/\/\$repo\/os\/\$arch/}"
        mirrors+=("$rsync_url")
      fi
    done < "$mirrorlist_file"
  fi
  
  printf '%s\n' "${mirrors[@]}"
}

# Проверяем доступность зеркал
find_working_mirror() {
  local mirrors=($(get_mirrors))
  
  for mirror in "${mirrors[@]}"; do
    if rsync --list-only --timeout=5 --contimeout=5 "$mirror" "$target" &>/dev/null; then
      echo "$mirror"
      return 0
    fi
  done
  
  return 1
}

# Команда rsync
rsync_cmd() {
  local -a cmd=(rsync -rlptH --safe-links --delete-delay --delay-updates
    "--timeout=600" "--contimeout=60" --no-motd)

  if stty &>/dev/null; then
    cmd+=(-h -v --progress)
  else
    cmd+=(--quiet)
  fi

  if ((bwlimit>0)); then
    cmd+=("--bwlimit=$bwlimit")
  fi

  "${cmd[@]}" "$@"
}

# Синхронизация зеркала
sync_mirror() {
  local force_sync="$1"
  
  print_colored $BLUE "🪞 Синхронизация официального зеркала..."
  
  # Блокировка
  exec 8>"$mirror_lock"
  if ! flock -n 8; then
    print_colored $RED "❌ Процесс синхронизации зеркала уже выполняется"
    return 1
  fi
  
  # Поиск рабочего зеркала
  local source_url=$(find_working_mirror)
  if [[ -z "$source_url" ]]; then
    print_colored $RED "❌ Ни одно зеркало недоступно"
    return 1
  fi
  
  print_colored $GREEN "✅ Используется зеркало: $source_url"
  
  # URL для проверки обновлений
  local lastupdate_url="${source_url/rsync:\/\/\//https:\/\/}/lastupdate"
  
  # Очистка временных файлов
  find "${target}" -name '.~~tmp~~' -exec rm -r {} + 2>/dev/null || true
  
  # Проверка необходимости синхронизации
  if [[ "$force_sync" != "true" ]] && ! tty -s && [[ -f "$target/lastupdate" ]]; then
    if diff -b <(curl -Ls "$lastupdate_url" 2>/dev/null) "$target/lastupdate" >/dev/null 2>&1; then
      print_colored $GREEN "✅ Зеркало актуально, синхронизация не требуется"
      rsync_cmd "$source_url/lastsync" "$target/lastsync" 2>/dev/null || true
      return 0
    fi
  fi
  
  # Синхронизация
  print_colored $BLUE "🔄 Запуск синхронизации..."
  if rsync_cmd \
    --exclude='gnome-unstable' \
    --exclude='multilib-testing' \
    --exclude='core-testing' \
    --exclude='multilib-staging' \
    --exclude='extra-staging' \
    --exclude='core-staging' \
    --exclude='extra-testing' \
    "${source_url}" \
    "${target}"; then
    
    # Обновляем lastupdate
    curl -Ls "$lastupdate_url" > "${target}/lastupdate" 2>/dev/null
    print_colored $GREEN "✅ Синхронизация зеркала завершена успешно"
    
    # Индексируем локальные репозитории
    index_local_repositories
  else
    print_colored $RED "❌ Ошибка синхронизации зеркала"
    return 1
  fi
}

# Индексация локальных репозиториев
index_local_repositories() {
  print_colored $BLUE "📦 Индексация локальных репозиториев..."
  
  for repo in core extra community multilib; do
    local repo_dir="$target/$repo/os/$arch"
    local db_name="${repo}-local.db.tar.gz"
    local db_path="$repo_dir/$db_name"
    local state_file="$repo_dir/${repo}-local.state"

    [[ ! -d "$repo_dir" ]] && continue

    # Вычисляем хэш состояния пакетов
    local current_pkg_files_details=""
    if compgen -G "$repo_dir/*.pkg.tar.zst" > /dev/null; then
        current_pkg_files_details=$(find "$repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%f\t%s\t%T@\n' | sort)
    fi
    local current_pkg_state_hash=$(echo -n "$current_pkg_files_details" | sha256sum | awk '{print $1}')

    local old_pkg_state_hash=""
    if [[ -f "$state_file" ]]; then
      old_pkg_state_hash=$(cat "$state_file")
    fi

    if [[ "$current_pkg_state_hash" != "$old_pkg_state_hash" ]]; then
      print_colored $YELLOW "🔄 Обновление базы данных $repo-local..."

      if repo-add "$db_path" "$repo_dir"/*.pkg.tar.zst 2>/dev/null; then
        echo "$current_pkg_state_hash" > "$state_file"
        print_colored $GREEN "  ✅ $repo-local индексирован"
      else
        print_colored $RED "  ❌ Ошибка индексации $repo-local"
      fi
    else
      print_colored $GREEN "  ✅ $repo-local актуален"
    fi
  done
}

# =============================================================================
# ФУНКЦИИ AUR
# =============================================================================

# Добавить пакеты AUR
add_aur_packages() {
  local packages=("$@")
  for pkg in "${packages[@]}"; do
    # Проверяем существование пакета в AUR
    print_colored $YELLOW "🔍 Проверка пакета $pkg в AUR..."
    if yay -Si "$pkg" >/dev/null 2>&1; then
      if ! grep -q "^$pkg$" "$aur_packages_file"; then
        echo "$pkg" >> "$aur_packages_file"
        print_colored $GREEN "✅ Пакет $pkg добавлен в список"
      else
        print_colored $YELLOW "⚠️  Пакет $pkg уже в списке"
      fi
    else
      print_colored $RED "❌ Пакет $pkg не найден в AUR"
    fi
  done
}

# Удалить пакеты AUR
remove_aur_packages() {
  local packages=("$@")
  for pkg in "${packages[@]}"; do
    if grep -q "^$pkg$" "$aur_packages_file"; then
      sed -i "/^$pkg$/d" "$aur_packages_file"
      rm -f "$aur_repo_dir"/${pkg}-*.pkg.tar.zst
      print_colored $GREEN "✅ Пакет $pkg удален"
    else
      print_colored $YELLOW "⚠️  Пакет $pkg не найден в списке"
    fi
  done
}

# Сборка AUR пакетов
build_aur_packages() {
  if [ ! -s "$aur_packages_file" ]; then
    print_colored $YELLOW "📋 Список AUR пакетов пуст"
    return 0
  fi

  # Блокировка
  exec 7>"$aur_lock"
  if ! flock -n 7; then
    print_colored $RED "❌ Процесс сборки AUR уже выполняется"
    return 1
  fi

  # Создаем временную директорию для сборки
  mkdir -p "$build_dir"
  cd "$build_dir" || exit 1

  local built_packages=()
  local failed_packages=()
  local total_packages=$(grep -c '^[^#]' "$aur_packages_file")
  local current=0

  print_colored $BLUE "🔨 Начинаем сборку AUR пакетов..."

  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
    
    ((current++))
    print_colored $BLUE "[$current/$total_packages] 📦 Обработка: $package"
    
    # Проверяем необходимость пересборки
    local needs_rebuild=false
    if [[ "$force_rebuild" == "true" ]]; then
      needs_rebuild=true
      print_colored $YELLOW "🔄 Принудительная пересборка"
    else
      local aur_version=$(yay -Si "$package" 2>/dev/null | grep "^Version" | awk '{print $3}')
      local local_pkg=$(find "$aur_repo_dir" -name "${package}-*.pkg.tar.zst" -printf '%f\n' | head -1)
      
      if [[ -z "$local_pkg" ]] || [[ -z "$aur_version" ]]; then
        needs_rebuild=true
      elif [[ "$local_pkg" != *"$aur_version"* ]]; then
        needs_rebuild=true
        print_colored $YELLOW "🆕 Обнаружена новая версия"
      else
        print_colored $GREEN "✅ Пакет актуален"
      fi
    fi

    if [[ "$needs_rebuild" == "true" ]]; then
      rm -f "$aur_repo_dir"/${package}-*.pkg.tar.zst
      
      local yay_opts="--noconfirm --needed"
      [[ "$quiet" == "true" ]] && yay_opts="$yay_opts --quiet"
      
      if yay -S $yay_opts "$package"; then
        local pkg_file=$(find /home/$USER/.cache/yay/"$package" -name "*.pkg.tar.zst" -type f | head -1)
        if [[ -n "$pkg_file" && -f "$pkg_file" ]]; then
          cp "$pkg_file" "$aur_repo_dir/"
          built_packages+=("$package")
          print_colored $GREEN "✅ Собран: $package"
        else
          print_colored $RED "❌ Файл пакета не найден: $package"
          failed_packages+=("$package")
        fi
      else
        print_colored $RED "❌ Ошибка сборки: $package"
        failed_packages+=("$package")
      fi
    fi
  done < "$aur_packages_file"

  # Очистка
  cd /
  rm -rf "$build_dir"

  # Отчет
  echo ""
  print_colored $BLUE "📊 Отчет о сборке AUR:"
  if [[ ${#built_packages[@]} -gt 0 ]]; then
    print_colored $GREEN "✅ Собрано: ${#built_packages[@]}"
    printf '   %s\n' "${built_packages[@]}"
  fi
  
  if [[ ${#failed_packages[@]} -gt 0 ]]; then
    print_colored $RED "❌ Ошибки: ${#failed_packages[@]}"
    printf '   %s\n' "${failed_packages[@]}"
  fi

  if [[ ${#built_packages[@]} -eq 0 && ${#failed_packages[@]} -eq 0 ]]; then
    print_colored $GREEN "ℹ️  Все пакеты актуальны"
  fi

  # Обновляем базу данных
  update_aur_repository
}

# Обновление базы данных AUR
update_aur_repository() {
  print_colored $BLUE "🔄 Обновление базы данных AUR..."
  
  local current_pkg_files_details=""
  if compgen -G "$aur_repo_dir/*.pkg.tar.zst" > /dev/null; then
      current_pkg_files_details=$(find "$aur_repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%f\t%s\t%T@\n' | sort)
  fi
  local current_pkg_state_hash=$(echo -n "$current_pkg_files_details" | sha256sum | awk '{print $1}')

  local old_pkg_state_hash=""
  if [[ -f "$aur_state_file" ]]; then
    old_pkg_state_hash=$(cat "$aur_state_file")
  fi

  if [[ "$current_pkg_state_hash" != "$old_pkg_state_hash" ]]; then
    rm -f "$aur_repo_dir"/aur-local.db* "$aur_repo_dir"/aur-local.files*

    if compgen -G "$aur_repo_dir/*.pkg.tar.zst" > /dev/null; then
      if repo-add "$aur_db_path" "$aur_repo_dir"/*.pkg.tar.zst; then
        echo "$current_pkg_state_hash" > "$aur_state_file"
        print_colored $GREEN "✅ База данных AUR обновлена"
      else
        print_colored $RED "❌ Ошибка обновления базы данных AUR"
        return 1
      fi
    else
      print_colored $YELLOW "⚠️  Пакеты отсутствуют"
      rm -f "$aur_state_file"
    fi
  else
    print_colored $GREEN "ℹ️  База данных AUR актуальна"
  fi
}

# Очистка старых AUR пакетов
clean_aur_packages() {
  local keep_packages=()
  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
    keep_packages+=("$package")
  done < "$aur_packages_file"
  
  local to_remove=()
  for pkg_file in "$aur_repo_dir"/*.pkg.tar.zst; do
    [[ ! -f "$pkg_file" ]] && continue
    
    local pkg_name=$(basename "$pkg_file" | sed 's/-[^-]*-[^-]*\.pkg\.tar\.zst$//')
    local found=false
    
    for keep_pkg in "${keep_packages[@]}"; do
      if [[ "$pkg_name" == "$keep_pkg" ]]; then
        found=true
        break
      fi
    done
    
    if [[ "$found" == "false" ]]; then
      to_remove+=("$(basename "$pkg_file")")
    fi
  done
  
  if [[ ${#to_remove[@]} -gt 0 ]]; then
    print_colored $YELLOW "🗑️  Найдено старых пакетов: ${#to_remove[@]}"
    for pkg in "${to_remove[@]}"; do
      rm -f "$aur_repo_dir/$pkg"
      print_colored $GREEN "  ✅ Удален: $pkg"
    done
    update_aur_repository
  else
    print_colored $GREEN "✅ Старые пакеты не найдены"
  fi
}

# =============================================================================
# НАСТРОЙКИ PACMAN
# =============================================================================

# Настройка pacman.conf
setup_pacman_conf() {
  local pacman_conf="/etc/pacman.conf"
  
  print_colored $BLUE "🗂️  Настройка pacman.conf..."
  echo ""
  
  # Проверяем существующие записи
  local has_core_local=$(grep -q "^\[core-local\]" "$pacman_conf" && echo "true" || echo "false")
  local has_extra_local=$(grep -q "^\[extra-local\]" "$pacman_conf" && echo "true" || echo "false")
  local has_multilib_local=$(grep -q "^\[multilib-local\]" "$pacman_conf" && echo "true" || echo "false")
  local has_aur_local=$(grep -q "^\[aur-local\]" "$pacman_conf" && echo "true" || echo "false")
  
  echo "Статус локальных репозиториев в pacman.conf:"
  echo "  [core-local]: $(if [[ "$has_core_local" == "true" ]]; then echo "✅"; else echo "❌"; fi)"
  echo "  [extra-local]: $(if [[ "$has_extra_local" == "true" ]]; then echo "✅"; else echo "❌"; fi)"
  echo "  [multilib-local]: $(if [[ "$has_multilib_local" == "true" ]]; then echo "✅"; else echo "❌"; fi)"
  echo "  [aur-local]: $(if [[ "$has_aur_local" == "true" ]]; then echo "✅"; else echo "❌"; fi)"
  echo ""
  
  # Создаем конфигурацию для добавления
  local temp_file=$(mktemp)
  local added_any=false
  
  if [[ "$has_core_local" == "false" ]] && [[ -d "$target/core/os/$arch" ]]; then
    echo -e "\n# Локальный core репозиторий\n[core-local]\nSigLevel = Optional TrustAll\nServer = file://$target/core/os/\$arch" >> "$temp_file"
    added_any=true
  fi
  
  if [[ "$has_extra_local" == "false" ]] && [[ -d "$target/extra/os/$arch" ]]; then
    echo -e "\n# Локальный extra репозиторий\n[extra-local]\nSigLevel = Optional TrustAll\nServer = file://$target/extra/os/\$arch" >> "$temp_file"
    added_any=true
  fi
  
  if [[ "$has_multilib_local" == "false" ]] && [[ -d "$target/multilib/os/$arch" ]]; then
    echo -e "\n# Локальный multilib репозиторий\n[multilib-local]\nSigLevel = Optional TrustAll\nServer = file://$target/multilib/os/\$arch" >> "$temp_file"
    added_any=true
  fi
  
  if [[ "$has_aur_local" == "false" ]] && [[ -d "$aur_repo_dir" ]]; then
    echo -e "\n# Локальный AUR репозиторий\n[aur-local]\nSigLevel = Optional TrustAll\nServer = file://$aur_target/os/\$arch" >> "$temp_file"
    added_any=true
  fi
  
  if [[ "$added_any" == "true" ]]; then
    echo "Будут добавлены следующие записи:"
    print_colored $CYAN "$(cat "$temp_file")"
    echo ""
    
    if confirm "Добавить записи в $pacman_conf?"; then
      if sudo tee -a "$pacman_conf" < "$temp_file" >/dev/null; then
        print_colored $GREEN "✅ Записи успешно добавлены"
        if confirm "Обновить базы данных (sudo pacman -Sy)?"; then
          sudo pacman -Sy
        fi
      else
        print_colored $RED "❌ Ошибка при добавлении записей"
      fi
    fi
  else
    print_colored $GREEN "✅ Все локальные репозитории уже настроены"
  fi
  
  rm -f "$temp_file"
}

# =============================================================================
# ИНТЕРАКТИВНЫЕ МЕНЮ
# =============================================================================

# Главное меню
show_main_menu() {
  show_header
  show_status
  
  print_colored $PURPLE "🎛️  Главное меню:"
  echo "  1) 🪞 Управление зеркалом Arch"
  echo "  2) 📦 Управление AUR репозиторием"
  echo "  3) ⚙️  Настройки"
  echo "  4) 🗂️  Настроить pacman.conf"
  echo "  5) 🔧 Утилиты"
  echo "  0) 🚪 Выход"
  echo ""
}

# Меню зеркала
mirror_menu() {
  while true; do
    show_header
    print_colored $BLUE "🪞 Управление зеркалом Arch Linux"
    echo ""
    
    echo "  1) 🔄 Синхронизировать зеркало"
    echo "  2) 🔨 Принудительная синхронизация"
    echo "  3) 📦 Переиндексировать локальные репозитории"
    echo "  4) 📊 Статус зеркала"
    echo "  0) ⬅️  Назад"
    echo ""
    
    local choice=$(read_input "Выберите действие")
    
    case $choice in
      1)
        sync_mirror false
        read -p "Нажмите Enter для продолжения..."
        ;;
      2)
        if confirm "Выполнить принудительную синхронизацию?"; then
          sync_mirror true
        fi
        read -p "Нажмите Enter для продолжения..."
        ;;
      3)
        index_local_repositories
        read -p "Нажмите Enter для продолжения..."
        ;;
      4)
        show_mirror_status
        read -p "Нажмите Enter для продолжения..."
        ;;
      0)
        break
        ;;
      *)
        print_colored $RED "❌ Неверный выбор"
        sleep 1
        ;;
    esac
  done
}

# Показать статус зеркала
show_mirror_status() {
  show_header
  print_colored $BLUE "📊 Подробный статус зеркала"
  echo ""
  
  if [[ -f "$target/lastupdate" ]]; then
    local timestamp=$(cat "$target/lastupdate")
    local last_update=$(date -d "@$timestamp" 2>/dev/null || echo "неизвестно")
    print_colored $GREEN "📅 Последнее обновление: $last_update"
  else
    print_colored $YELLOW "⚠️  Информация об обновлении отсутствует"
  fi
  
  if [[ -f "$target/lastsync" ]]; then
    local sync_timestamp=$(cat "$target/lastsync")
    local last_sync=$(date -d "@$sync_timestamp" 2>/dev/null || echo "неизвестно")
    print_colored $GREEN "🔄 Последняя синхронизация: $last_sync"
  fi
  
  echo ""
  print_colored $BLUE "📁 Репозитории и размеры:"
  for repo in core extra community multilib; do
    if [[ -d "$target/$repo" ]]; then
      local size=$(du -sh "$target/$repo" 2>/dev/null | cut -f1)
      local pkg_count=$(find "$target/$repo" -name "*.pkg.tar.zst" -type f 2>/dev/null | wc -l)
      print_colored $GREEN "  ✅ $repo: $size ($pkg_count пакетов)"
      
      # Статус локального репозитория
      local local_db="$target/$repo/os/$arch/${repo}-local.db.tar.gz"
      if [[ -f "$local_db" ]]; then
        local local_pkg_count=$(find "$target/$repo/os/$arch" -name "*.pkg.tar.zst" -type f 2>/dev/null | wc -l)
        print_colored $CYAN "    📦 $repo-local: $local_pkg_count локальных пакетов"
      fi
    else
      print_colored $RED "  ❌ $repo: отсутствует"
    fi
  done
  
  echo ""
  print_colored $BLUE "🌐 Доступные зеркала:"
  local mirrors=($(get_mirrors))
  for mirror in "${mirrors[@]}"; do
    if rsync --list-only --timeout=3 --contimeout=3 "$mirror" "$target" &>/dev/null; then
      print_colored $GREEN "  ✅ $mirror"
    else
      print_colored $RED "  ❌ $mirror"
    fi
  done
}

# Меню AUR
aur_menu() {
  while true; do
    show_header
    print_colored $BLUE "📦 Управление AUR репозиторием"
    echo ""
    
    local pkg_count=$(grep -c '^[^#]' "$aur_packages_file" 2>/dev/null || echo 0)
    echo "📋 Пакетов в списке: $pkg_count"
    echo ""
    
    echo "  1) 📋 Показать список пакетов"
    echo "  2) ➕ Добавить пакеты"
    echo "  3) ➖ Удалить пакеты"
    echo "  4) 🔨 Собрать пакеты"
    echo "  5) 🔄 Обновить базу данных"
    echo "  6) 🧹 Очистить старые пакеты"
    echo "  7) ℹ️  Информация о пакете"
    echo "  0) ⬅️  Назад"
    echo ""
    
    local choice=$(read_input "Выберите действие")
    
    case $choice in
      1)
        list_aur_packages
        ;;
      2)
        add_aur_packages_interactive
        ;;
      3)
        remove_aur_packages_interactive
        ;;
      4)
        if confirm "Начать сборку AUR пакетов?"; then
          build_aur_packages
        fi
        read -p "Нажмите Enter для продолжения..."
        ;;
      5)
        update_aur_repository
        read -p "Нажмите Enter для продолжения..."
        ;;
      6)
        if confirm "Очистить старые пакеты?"; then
          clean_aur_packages
        fi
        read -p "Нажмите Enter для продолжения..."
        ;;
      7)
        show_aur_package_info
        ;;
      0)
        break
        ;;
      *)
        print_colored $RED "❌ Неверный выбор"
        sleep 1
        ;;
    esac
  done
}

# Список AUR пакетов
list_aur_packages() {
  show_header
  print_colored $BLUE "📋 Список AUR пакетов"
  echo ""
  
  if [[ ! -s "$aur_packages_file" ]]; then
    print_colored $YELLOW "Список пакетов пуст"
  else
    local i=1
    while IFS= read -r package; do
      [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
      
      local status_icon="❓"
      local pkg_file=$(find "$aur_repo_dir" -name "${package}-*.pkg.tar.zst" -type f | head -1)
      
      if [[ -n "$pkg_file" ]]; then
        status_icon="✅"
        local pkg_size=$(du -h "$pkg_file" | cut -f1)
        echo "  $i) $status_icon $package (собран, $pkg_size)"
      else
        status_icon="❌"
        echo "  $i) $status_icon $package (не собран)"
      fi
      ((i++))
    done < "$aur_packages_file"
  fi
  
  echo ""
  read -p "Нажмите Enter для возврата..."
}

# Добавить AUR пакеты
add_aur_packages_interactive() {
  show_header
  print_colored $BLUE "➕ Добавление AUR пакетов"
  echo ""
  
  while true; do
    local package=$(read_input "Введите имя пакета AUR (или 'q' для выхода)")
    
    if [[ "$package" == "q" || "$package" == "Q" ]]; then
      break
    fi
    
    if [[ -z "$package" ]]; then
      print_colored $YELLOW "Имя пакета не может быть пустым"
      continue
    fi
    
    add_aur_packages "$package"
    echo ""
  done
}

# Удалить AUR пакеты
remove_aur_packages_interactive() {
  show_header
  print_colored $BLUE "➖ Удаление AUR пакетов"
  echo ""
  
  if [[ ! -s "$aur_packages_file" ]]; then
    print_colored $YELLOW "Список пакетов пуст"
    read -p "Нажмите Enter для возврата..."
    return
  fi
  
  local packages=()
  local i=1
  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
    packages+=("$package")
    echo "  $i) $package"
    ((i++))
  done < "$aur_packages_file"
  
  echo ""
  local choice=$(read_input "Введите номер пакета для удаления (или 'q' для выхода)")
  
  if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    return
  fi
  
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#packages[@]} ]]; then
    local package_to_remove="${packages[$((choice-1))]}"
    
    if confirm "Удалить пакет '$package_to_remove'?"; then
      remove_aur_packages "$package_to_remove"
    fi
  else
    print_colored $RED "❌ Неверный номер пакета"
  fi
  
  echo ""
  read -p "Нажмите Enter для продолжения..."
}

# Информация о AUR пакете
show_aur_package_info() {
  show_header
  print_colored $BLUE "ℹ️  Информация о AUR пакете"
  echo ""
  
  local package=$(read_input "Введите имя пакета")
  
  if [[ -z "$package" ]]; then
    print_colored $RED "❌ Имя пакета не может быть пустым"
    read -p "Нажмите Enter для возврата..."
    return
  fi
  
  echo ""
  print_colored $BLUE "📦 Информация о пакете: $package"
  echo ""
  
  # Статус в списке
  if grep -q "^$package$" "$aur_packages_file"; then
    print_colored $GREEN "✅ Пакет в списке для сборки"
  else
    print_colored $YELLOW "⚠️  Пакет НЕ в списке для сборки"
  fi
  
  # Локальная версия
  local local_pkg=$(find "$aur_repo_dir" -name "${package}-*.pkg.tar.zst" -type f | head -1)
  if [[ -n "$local_pkg" ]]; then
    local pkg_size=$(du -h "$local_pkg" | cut -f1)
    local pkg_date=$(date -r "$local_pkg" "+%Y-%m-%d %H:%M")
    print_colored $GREEN "📁 Локальная версия: $(basename "$local_pkg")"
    echo "   💾 Размер: $pkg_size"
    echo "   📅 Дата сборки: $pkg_date"
  else
    print_colored $YELLOW "📁 Локальная версия: отсутствует"
  fi
  
  # Информация из AUR
  echo ""
  print_colored $BLUE "🌐 Информация из AUR:"
  if yay -Si "$package" 2>/dev/null; then
    echo ""
  else
    print_colored $RED "❌ Пакет не найден в AUR"
  fi
  
  read -p "Нажмите Enter для возврата..."
}

# Меню настроек
settings_menu() {
  while true; do
    show_header
    print_colored $BLUE "⚙️  Настройки"
    echo ""
    
    echo "Текущие настройки:"
    echo "  1) Принудительная пересборка AUR: $(if $force_rebuild; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
    echo "  2) Тихий режим: $(if $quiet; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
    echo "  3) Автоочистка: $(if $auto_clean; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
    echo "  4) Ограничение rsync: $(if ((bwlimit>0)); then echo "${bwlimit} КБ/с"; else echo 'ВЫКЛ'; fi)"
    echo "  5) Изменить пути"
    echo "  0) ⬅️  Назад"
    echo ""
    
    local choice=$(read_input "Выберите настройку")
    
    case $choice in
      1)
        force_rebuild=$(! $force_rebuild)
        print_colored $GREEN "Принудительная пересборка: $(if $force_rebuild; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
        sleep 1
        ;;
      2)
        quiet=$(! $quiet)
        print_colored $GREEN "Тихий режим: $(if $quiet; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
        sleep 1
        ;;
      3)
        auto_clean=$(! $auto_clean)
        print_colored $GREEN "Автоочистка: $(if $auto_clean; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
        sleep 1
        ;;
      4)
        local new_limit=$(read_input "Ограничение rsync в КБ/с (0 = без ограничений)" "$bwlimit")
        if [[ "$new_limit" =~ ^[0-9]+$ ]]; then
          bwlimit=$new_limit
          print_colored $GREEN "Ограничение установлено: $(if ((bwlimit>0)); then echo "${bwlimit} КБ/с"; else echo 'ВЫКЛ'; fi)"
        else
          print_colored $RED "❌ Неверное значение"
        fi
        sleep 1
        ;;
      5)
        show_paths_info
        ;;
      0)
        break
        ;;
      *)
        print_colored $RED "❌ Неверный выбор"
        sleep 1
        ;;
    esac
  done
}

# Информация о путях
show_paths_info() {
  show_header
  print_colored $BLUE "📁 Конфигурация путей"
  echo ""
  
  echo "Текущие пути:"
  echo "  🗂️  Основная директория: $target"
  echo "  📦 AUR репозиторий: $aur_target"
  echo "  📋 Список AUR пакетов: $aur_packages_file"
  echo "  🪞 Файл mirrorlist: $mirrorlist_file"
  echo "  🏗️  Временная сборка: $build_dir"
  echo ""
  
  local total_size=$(du -sh "$target" 2>/dev/null | cut -f1 || echo "0")
  print_colored $BLUE "💾 Общий размер: $total_size"
  
  echo ""
  read -p "Нажмите Enter для возврата..."
}

# Меню утилит
utilities_menu() {
  while true; do
    show_header
    print_colored $BLUE "🔧 Утилиты"
    echo ""
    
    echo "  1) 🧹 Полная очистка кэшей"
    echo "  2) 🔍 Проверка зависимостей"
    echo "  3) 📊 Подробная статистика"
    echo "  4) 🔧 Проверка целостности"
    echo "  5) 📝 Экспорт конфигурации"
    echo "  6) 📥 Импорт списка пакетов"
    echo "  0) ⬅️  Назад"
    echo ""
    
    local choice=$(read_input "Выберите утилиту")
    
    case $choice in
      1)
        full_cleanup
        ;;
      2)
        check_dependencies
        read -p "Нажмите Enter для продолжения..."
        ;;
      3)
        show_detailed_stats
        ;;
      4)
        check_integrity
        ;;
      5)
        export_config
        ;;
      6)
        import_package_list
        ;;
      0)
        break
        ;;
      *)
        print_colored $RED "❌ Неверный выбор"
        sleep 1
        ;;
    esac
  done
}

# Полная очистка
full_cleanup() {
  show_header
  print_colored $BLUE "🧹 Полная очистка кэшей"
  echo ""
  
  print_colored $YELLOW "⚠️  Это действие очистит:"
  echo "  - Кэш yay"
  echo "  - Временные файлы сборки"
  echo "  - Старые базы данных"
  echo ""
  
  if confirm "Продолжить очистку?"; then
    print_colored $BLUE "🧹 Очистка кэша yay..."
    yay -Sc --noconfirm >/dev/null 2>&1
    
    print_colored $BLUE "🧹 Очистка временных файлов..."
    rm -rf /tmp/aur-build-* 2>/dev/null
    find "${target}" -name '.~~tmp~~' -exec rm -r {} + 2>/dev/null
    
    print_colored $BLUE "🧹 Очистка старых баз данных..."
    find "$target" -name "*.db.tar.gz.old" -delete 2>/dev/null
    find "$target" -name "*.files.tar.gz.old" -delete 2>/dev/null
    
    print_colored $GREEN "✅ Очистка завершена"
  fi
  
  read -p "Нажмите Enter для продолжения..."
}

# Подробная статистика
show_detailed_stats() {
  show_header
  print_colored $BLUE "📊 Подробная статистика"
  echo ""
  
  # Общая статистика
  print_colored $WHITE "📈 Общая статистика:"
  local total_size=$(du -sh "$target" 2>/dev/null | cut -f1 || echo "0")
  local total_packages=0
  
  for repo in core extra community multilib; do
    if [[ -d "$target/$repo" ]]; then
      local count=$(find "$target/$repo" -name "*.pkg.tar.zst" -type f 2>/dev/null | wc -l)
      total_packages=$((total_packages + count))
    fi
  done
  
  local aur_packages=$(find "$aur_repo_dir" -name "*.pkg.tar.zst" -type f 2>/dev/null | wc -l)
  total_packages=$((total_packages + aur_packages))
  
  echo "  💾 Общий размер: $total_size"
  echo "  📦 Всего пакетов: $total_packages"
  echo ""
  
  # Статистика по репозиториям
  print_colored $WHITE "📁 По репозиториям:"
  for repo in core extra community multilib; do
    if [[ -d "$target/$repo" ]]; then
      local repo_size=$(du -sh "$target/$repo" 2>/dev/null | cut -f1)
      local repo_packages=$(find "$target/$repo" -name "*.pkg.tar.zst" -type f 2>/dev/null | wc -l)
      echo "  $repo: $repo_size ($repo_packages пакетов)"
    fi
  done
  
  if [[ -d "$aur_repo_dir" ]]; then
    local aur_size=$(du -sh "$aur_repo_dir" 2>/dev/null | cut -f1)
    echo "  aur-local: $aur_size ($aur_packages пакетов)"
  fi
  
  echo ""
  
  # Статистика использования
  print_colored $WHITE "⏱️  Временные метки:"
  if [[ -f "$target/lastupdate" ]]; then
    local last_update=$(date -d "@$(cat "$target/lastupdate")" 2>/dev/null || echo "неизвестно")
    echo "  📅 Последнее обновление зеркала: $last_update"
  fi
  
  if [[ -f "$aur_state_file" ]]; then
    local aur_update=$(date -r "$aur_state_file" 2>/dev/null || echo "неизвестно")
    echo "  📅 Последнее обновление AUR: $aur_update"
  fi
  
  read -p "Нажмите Enter для продолжения..."
}

# Проверка целостности
check_integrity() {
  show_header
  print_colored $BLUE "🔧 Проверка целостности"
  echo ""
  
  print_colored $BLUE "🔍 Проверка структуры директорий..."
  local errors=0
  
  # Проверка основных директорий
  for dir in "$target" "$aur_repo_dir"; do
    if [[ ! -d "$dir" ]]; then
      print_colored $RED "❌ Отсутствует директория: $dir"
      ((errors++))
    fi
  done
  
  # Проверка файлов конфигурации
  if [[ ! -f "$aur_packages_file" ]]; then
    print_colored $RED "❌ Отсутствует файл списка AUR пакетов"
    ((errors++))
  fi
  
  # Проверка баз данных
  print_colored $BLUE "🔍 Проверка баз данных..."
  for repo in core extra community multilib; do
    local repo_dir="$target/$repo/os/$arch"
    if [[ -d "$repo_dir" ]]; then
      local db_file="$repo_dir/${repo}-local.db.tar.gz"
      if [[ -f "$db_file" ]]; then
        if ! tar -tf "$db_file" >/dev/null 2>&1; then
          print_colored $RED "❌ Повреждена база данных: $db_file"
          ((errors++))
        fi
      fi
    fi
  done
  
  if [[ -f "$aur_db_path" ]]; then
    if ! tar -tf "$aur_db_path" >/dev/null 2>&1; then
      print_colored $RED "❌ Повреждена база данных AUR"
      ((errors++))
    fi
  fi
  
  # Проверка блокировок
  print_colored $BLUE "🔍 Проверка блокировок..."
  for lock_file in "$mirror_lock" "$aur_lock"; do
    if [[ -f "$lock_file" ]]; then
      if ! flock -n "$lock_file" true 2>/dev/null; then
        print_colored $YELLOW "⚠️  Активная блокировка: $lock_file"
      fi
    fi
  done
  
  if [[ $errors -eq 0 ]]; then
    print_colored $GREEN "✅ Проверка целостности пройдена"
  else
    print_colored $RED "❌ Обнаружено ошибок: $errors"
  fi
  
  read -p "Нажмите Enter для продолжения..."
}

# Экспорт конфигурации
export_config() {
  show_header
  print_colored $BLUE "📝 Экспорт конфигурации"
  echo ""
  
  local export_file="$target/arch-repo-config-$(date +%Y%m%d-%H%M%S).txt"
  
  cat > "$export_file" << EOF
# Конфигурация Arch Repo Manager
# Экспортировано: $(date)

# Пути
TARGET_DIR=$target
AUR_TARGET_DIR=$aur_target
PACKAGES_FILE=$aur_packages_file

# Настройки
FORCE_REBUILD=$force_rebuild
QUIET_MODE=$quiet
AUTO_CLEAN=$auto_clean
BANDWIDTH_LIMIT=$bwlimit

# AUR пакеты
EOF
  
  if [[ -f "$aur_packages_file" ]]; then
    echo "AUR_PACKAGES=(" >> "$export_file"
    while IFS= read -r package; do
      [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
      echo "  \"$package\"" >> "$export_file"
    done < "$aur_packages_file"
    echo ")" >> "$export_file"
  fi
  
  print_colored $GREEN "✅ Конфигурация экспортирована: $export_file"
  read -p "Нажмите Enter для продолжения..."
}

# Импорт списка пакетов
import_package_list() {
  show_header
  print_colored $BLUE "📥 Импорт списка пакетов"
  echo ""
  
  local import_file=$(read_input "Путь к файлу со списком пакетов")
  
  if [[ ! -f "$import_file" ]]; then
    print_colored $RED "❌ Файл не найден: $import_file"
    read -p "Нажмите Enter для продолжения..."
    return
  fi
  
  local count=0
  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
    
    if ! grep -q "^$package$" "$aur_packages_file"; then
      echo "$package" >> "$aur_packages_file"
      print_colored $GREEN "✅ Добавлен: $package"
      ((count++))
    else
      print_colored $YELLOW "⚠️  Уже существует: $package"
    fi
  done < "$import_file"
  
  print_colored $GREEN "📥 Импортировано пакетов: $count"
  read -p "Нажмите Enter для продолжения..."
}

# =============================================================================
# ГЛАВНЫЙ ИНТЕРФЕЙС
# =============================================================================

# Главный цикл
main_interface() {
  while true; do
    show_main_menu
    
    local choice=$(read_input "Выберите действие")
    
    case $choice in
      1)
        mirror_menu
        ;;
      2)
        aur_menu
        ;;
      3)
        settings_menu
        ;;
      4)
        setup_pacman_conf
        read -p "Нажмите Enter для продолжения..."
        ;;
      5)
        utilities_menu
        ;;
      0)
        print_colored $GREEN "👋 До свидания!"
        exit 0
        ;;
      *)
        print_colored $RED "❌ Неверный выбор. Попробуйте снова."
        sleep 1
        ;;
    esac
  done
}

# =============================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# =============================================================================

main() {
  # Настройка и проверки
  setup_directories
  
  # Проверяем зависимости (но не завершаем при их отсутствии)
  check_dependencies
  
  # Если нет параметров - запускаем интерактивный режим
  if [[ $# -eq 0 ]]; then
    main_interface
  else
    # Поддержка базовых параметров для автоматизации
    case "$1" in
      "sync")
        sync_mirror false
        ;;
      "sync-force")
        sync_mirror true
        ;;
      "build-aur")
        build_aur_packages
        ;;
      "update-aur")
        update_aur_repository
        ;;
      *)
        print_colored $YELLOW "⚠️  Неизвестный параметр: $1"
        print_colored $BLUE "Поддерживаемые команды: sync, sync-force, build-aur, update-aur"
        print_colored $BLUE "Запустите без параметров для интерактивного режима"
        exit 1
        ;;
    esac
  fi
}

# Запуск
main "$@" 