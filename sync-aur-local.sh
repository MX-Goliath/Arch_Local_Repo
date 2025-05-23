#!/bin/bash

########
#
# Скрипт для автоматической сборки и управления локальным репозиторием AUR пакетов
# Основан на sync-arch-mirror.sh
#
########

# Директория где хранится локальный репозиторий (та же что и у основного скрипта)
target="/home/$USER/arch-mirror-repo"

# Директория для AUR репозитория
aur_target="$target/aur"

# Файл блокировки
lock="$target/syncaur.lck"

# Файл со списком AUR пакетов для сборки (один пакет на строку)
aur_packages_file="$target/aur-packages.list"

# Временная директория для сборки
build_dir="/tmp/aur-build-$$"

# Определяем архитектуру
arch=$(uname -m)

# Директория AUR репозитория
aur_repo_dir="$aur_target/os/$arch"
db_name="aur-local.db.tar.gz"
db_path="$aur_repo_dir/$db_name"
state_file="$aur_repo_dir/aur-local.state"

# Глобальные переменные для настроек
force_rebuild=false
quiet=false

# Цвета для интерфейса
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# Создаем необходимые директории
setup_directories() {
  [ ! -d "$target" ] && mkdir -p "$target"
  [ ! -d "$aur_repo_dir" ] && mkdir -p "$aur_repo_dir"
  [ ! -f "$aur_packages_file" ] && touch "$aur_packages_file"
}

# Проверяем наличие yay
check_yay() {
  if ! command -v yay >/dev/null 2>&1; then
    print_colored $RED "Ошибка: yay не установлен. Установите yay для работы с AUR."
    exit 1
  fi
}

# Показываем заголовок
show_header() {
  clear
  print_colored $CYAN "╔══════════════════════════════════════════════════════════════════╗"
  print_colored $CYAN "║                    Менеджер локального AUR репозитория           ║"
  print_colored $CYAN "╚══════════════════════════════════════════════════════════════════╝"
  echo ""
}

# Показываем статус репозитория
show_status() {
  local pkg_count=0
  local repo_size=0
  
  if [[ -f "$aur_packages_file" ]]; then
    pkg_count=$(grep -c '^[^#]' "$aur_packages_file" 2>/dev/null || echo 0)
  fi
  
  if [[ -d "$aur_repo_dir" ]]; then
    repo_size=$(du -sh "$aur_repo_dir" 2>/dev/null | cut -f1 || echo "0")
  fi
  
  print_colored $BLUE "Статус репозитория:"
  echo "  📦 Пакетов в списке: $pkg_count"
  echo "  💾 Размер репозитория: $repo_size"
  echo "  📁 Путь: $aur_repo_dir"
  
  if [[ -f "$db_path" ]]; then
    print_colored $GREEN "  ✅ База данных: создана"
  else
    print_colored $YELLOW "  ⚠️  База данных: не создана"
  fi
  echo ""
}

# Главное меню
show_main_menu() {
  show_header
  show_status
  
  print_colored $PURPLE "Выберите действие:"
  echo "  1) 📋 Показать список пакетов"
  echo "  2) ➕ Добавить пакеты"
  echo "  3) ➖ Удалить пакеты"
  echo "  4) 🔨 Собрать пакеты"
  echo "  5) ⚙️  Настройки сборки"
  echo "  6) 🗂️  Настроить pacman.conf"
  echo "  7) 🧹 Очистить старые пакеты"
  echo "  8) ℹ️  Информация о пакете"
  echo "  9) 🔄 Обновить базу данных"
  echo "  0) 🚪 Выход"
  echo ""
}

# Показать список пакетов
list_packages_interactive() {
  show_header
  print_colored $BLUE "📋 Список пакетов для сборки:"
  echo ""
  
  if [[ ! -s "$aur_packages_file" ]]; then
    print_colored $YELLOW "Список пакетов пуст"
  else
    local i=1
    while IFS= read -r package; do
      [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
      
      # Проверяем статус пакета
      local status_icon="❓"
      local pkg_file=$(find "$aur_repo_dir" -name "${package}-*.pkg.tar.zst" -type f | head -1)
      
      if [[ -n "$pkg_file" ]]; then
        status_icon="✅"
      else
        status_icon="❌"
      fi
      
      echo "  $i) $status_icon $package"
      ((i++))
    done < "$aur_packages_file"
  fi
  
  echo ""
  read -p "Нажмите Enter для возврата в меню..."
}

# Добавить пакеты
add_packages_interactive() {
  show_header
  print_colored $BLUE "➕ Добавление пакетов в список"
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
    
    # Проверяем существование пакета в AUR
    print_colored $YELLOW "Проверка пакета $package в AUR..."
    if yay -Si "$package" >/dev/null 2>&1; then
      if ! grep -q "^$package$" "$aur_packages_file"; then
        echo "$package" >> "$aur_packages_file"
        print_colored $GREEN "✅ Пакет $package добавлен в список"
      else
        print_colored $YELLOW "⚠️  Пакет $package уже в списке"
      fi
    else
      print_colored $RED "❌ Пакет $package не найден в AUR"
    fi
    echo ""
  done
}

# Удалить пакеты
remove_packages_interactive() {
  show_header
  print_colored $BLUE "➖ Удаление пакетов из списка"
  echo ""
  
  if [[ ! -s "$aur_packages_file" ]]; then
    print_colored $YELLOW "Список пакетов пуст"
    read -p "Нажмите Enter для возврата в меню..."
    return
  fi
  
  # Показываем пронумерованный список
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
      sed -i "/^$package_to_remove$/d" "$aur_packages_file"
      rm -f "$aur_repo_dir"/${package_to_remove}-*.pkg.tar.zst
      print_colored $GREEN "✅ Пакет $package_to_remove удален"
    fi
  else
    print_colored $RED "❌ Неверный номер пакета"
  fi
  
  echo ""
  read -p "Нажмите Enter для возврата в меню..."
}

# Настройки сборки
build_settings_interactive() {
  show_header
  print_colored $BLUE "⚙️ Настройки сборки"
  echo ""
  
  while true; do
    echo "Текущие настройки:"
    echo "  1) Принудительная пересборка: $(if $force_rebuild; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
    echo "  2) Тихий режим: $(if $quiet; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
    echo "  0) Назад"
    echo ""
    
    local choice=$(read_input "Выберите настройку для изменения")
    
    case $choice in
      1)
        force_rebuild=$(! $force_rebuild)
        print_colored $GREEN "Принудительная пересборка: $(if $force_rebuild; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
        ;;
      2)
        quiet=$(! $quiet)
        print_colored $GREEN "Тихий режим: $(if $quiet; then echo 'ВКЛ'; else echo 'ВЫКЛ'; fi)"
        ;;
      0)
        break
        ;;
      *)
        print_colored $RED "❌ Неверный выбор"
        ;;
    esac
    echo ""
  done
}

# Собираем пакеты
build_packages() {
  if [ ! -s "$aur_packages_file" ]; then
    print_colored $YELLOW "Список пакетов пуст. Добавьте пакеты перед сборкой."
    return 0
  fi

  # Создаем временную директорию для сборки
  mkdir -p "$build_dir"
  cd "$build_dir" || exit 1

  local built_packages=()
  local failed_packages=()
  local total_packages=$(grep -c '^[^#]' "$aur_packages_file")
  local current=0

  while IFS= read -r package; do
    # Пропускаем пустые строки и комментарии
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
    
    ((current++))
    print_colored $BLUE "[$current/$total_packages] Обработка пакета: $package"
    
    # Проверяем, нужно ли пересобирать пакет
    local needs_rebuild=false
    if [[ "$force_rebuild" == "true" ]]; then
      needs_rebuild=true
      print_colored $YELLOW "Принудительная пересборка пакета $package"
    else
      # Проверяем версию пакета в AUR и локальную версию
      local aur_version=$(yay -Si "$package" 2>/dev/null | grep "^Version" | awk '{print $3}')
      local local_pkg=$(find "$aur_repo_dir" -name "${package}-*.pkg.tar.zst" -printf '%f\n' | head -1)
      
      if [[ -z "$local_pkg" ]] || [[ -z "$aur_version" ]]; then
        needs_rebuild=true
        print_colored $YELLOW "Пакет $package отсутствует локально или в AUR"
      else
        # Простая проверка - если файл не содержит версию из AUR, то пересобираем
        if [[ "$local_pkg" != *"$aur_version"* ]]; then
          needs_rebuild=true
          print_colored $YELLOW "Обнаружена новая версия пакета $package"
        else
          print_colored $GREEN "Пакет $package актуален"
        fi
      fi
    fi

    if [[ "$needs_rebuild" == "true" ]]; then
      # Удаляем старые версии пакета
      rm -f "$aur_repo_dir"/${package}-*.pkg.tar.zst
      
      # Сборка пакета
      local yay_opts="--noconfirm --needed"
      [[ "$quiet" == "true" ]] && yay_opts="$yay_opts --quiet"
      
      print_colored $BLUE "🔨 Сборка пакета $package..."
      if yay -S $yay_opts "$package"; then
        # Копируем собранный пакет в репозиторий
        local pkg_file=$(find /home/$USER/.cache/yay/"$package" -name "*.pkg.tar.zst" -type f | head -1)
        if [[ -n "$pkg_file" && -f "$pkg_file" ]]; then
          cp "$pkg_file" "$aur_repo_dir/"
          built_packages+=("$package")
          print_colored $GREEN "✅ Пакет $package успешно собран"
        else
          print_colored $RED "❌ Файл пакета для $package не найден в кэше yay"
          failed_packages+=("$package")
        fi
      else
        print_colored $RED "❌ Ошибка сборки пакета: $package"
        failed_packages+=("$package")
      fi
    fi
    echo ""
  done < "$aur_packages_file"

  # Очистка временной директории
  cd /
  rm -rf "$build_dir"

  # Отчет о сборке
  echo ""
  print_colored $BLUE "📊 Отчет о сборке:"
  if [[ ${#built_packages[@]} -gt 0 ]]; then
    print_colored $GREEN "✅ Успешно собрано пакетов: ${#built_packages[@]}"
    printf '   %s\n' "${built_packages[@]}"
  fi
  
  if [[ ${#failed_packages[@]} -gt 0 ]]; then
    print_colored $RED "❌ Не удалось собрать пакетов: ${#failed_packages[@]}"
    printf '   %s\n' "${failed_packages[@]}"
  fi

  if [[ ${#built_packages[@]} -eq 0 && ${#failed_packages[@]} -eq 0 ]]; then
    print_colored $YELLOW "ℹ️  Все пакеты актуальны, сборка не требуется"
  fi

  # Обновляем базу данных репозитория
  echo ""
  update_repository
}

# Сборка пакетов (интерактивная)
build_packages_interactive() {
  show_header
  print_colored $BLUE "🔨 Сборка пакетов"
  echo ""
  
  if [[ ! -s "$aur_packages_file" ]]; then
    print_colored $YELLOW "Список пакетов пуст. Добавьте пакеты перед сборкой."
    read -p "Нажмите Enter для возврата в меню..."
    return
  fi
  
  local pkg_count=$(grep -c '^[^#]' "$aur_packages_file")
  print_colored $BLUE "Найдено пакетов для сборки: $pkg_count"
  echo ""
  
  if confirm "Начать сборку пакетов?"; then
    build_packages
  fi
  
  echo ""
  read -p "Нажмите Enter для возврата в меню..."
}

# Обновляем базу данных репозитория
update_repository() {
  print_colored $BLUE "🔄 Обновление базы данных репозитория..."
  
  # Собираем информацию о текущих .pkg.tar.zst файлах
  current_pkg_files_details=""
  if compgen -G "$aur_repo_dir/*.pkg.tar.zst" > /dev/null; then
      current_pkg_files_details=$(find "$aur_repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%f\t%s\t%T@\n' | sort)
  fi
  current_pkg_state_hash=$(echo -n "$current_pkg_files_details" | sha256sum | awk '{print $1}')

  old_pkg_state_hash=""
  if [[ -f "$state_file" ]]; then
    old_pkg_state_hash=$(cat "$state_file")
  fi

  if [[ "$current_pkg_state_hash" != "$old_pkg_state_hash" ]]; then
    print_colored $YELLOW "Обнаружены изменения в AUR репозитории..."

    # Удаляем старую базу данных
    rm -f "$aur_repo_dir"/aur-local.db* "$aur_repo_dir"/aur-local.files*

    # Генерируем новую базу если есть пакеты
    if compgen -G "$aur_repo_dir/*.pkg.tar.zst" > /dev/null; then
      if repo-add "$db_path" "$aur_repo_dir"/*.pkg.tar.zst; then
        echo "$current_pkg_state_hash" > "$state_file"
        print_colored $GREEN "✅ База данных AUR репозитория успешно обновлена"
      else
        print_colored $RED "❌ Ошибка при обновлении базы данных AUR репозитория"
        return 1
      fi
    else
      print_colored $YELLOW "⚠️  Пакеты отсутствуют, база данных не создана"
      rm -f "$state_file"
    fi
  else
    print_colored $GREEN "ℹ️  Изменений в AUR репозитории не обнаружено"
  fi
}

# Обновление базы данных (интерактивное)
update_repository_interactive() {
  show_header
  print_colored $BLUE "🔄 Обновление базы данных"
  echo ""
  
  update_repository
  
  echo ""
  read -p "Нажмите Enter для возврата в меню..."
}

# Настройка pacman.conf
setup_pacman_interactive() {
  show_header
  print_colored $BLUE "🗂️ Настройка pacman.conf"
  echo ""
  
  local pacman_conf="/etc/pacman.conf"
  local repo_entry="[aur-local]
SigLevel = Optional TrustAll
Server = file://$aur_target/os/\$arch"

  if grep -q "^\[aur-local\]" "$pacman_conf"; then
    print_colored $GREEN "✅ Запись [aur-local] уже существует в $pacman_conf"
  else
    print_colored $YELLOW "⚠️  Запись [aur-local] отсутствует в $pacman_conf"
    echo ""
    echo "Будет добавлена следующая запись:"
    print_colored $CYAN "$repo_entry"
    echo ""
    
    if confirm "Добавить запись AUR репозитория в $pacman_conf?"; then
      # Создаем временный файл с новой записью
      local temp_file=$(mktemp)
      echo -e "\n# Локальный AUR репозиторий\n$repo_entry" > "$temp_file"
      
      # Добавляем запись в конец файла
      if sudo tee -a "$pacman_conf" < "$temp_file" >/dev/null; then
        print_colored $GREEN "✅ AUR репозиторий успешно добавлен в $pacman_conf"
        echo ""
        if confirm "Обновить базы данных пакетов (sudo pacman -Sy)?"; then
          sudo pacman -Sy
        fi
      else
        print_colored $RED "❌ Ошибка при добавлении записи в $pacman_conf"
      fi
      
      rm -f "$temp_file"
    fi
  fi
  
  echo ""
  read -p "Нажмите Enter для возврата в меню..."
}

# Очистка старых пакетов
clean_old_packages_interactive() {
  show_header
  print_colored $BLUE "🧹 Очистка старых пакетов"
  echo ""
  
  # Получаем список установленных пакетов из списка
  local keep_packages=()
  while IFS= read -r package; do
    [[ -z "$package" || "$package" =~ ^[[:space:]]*# ]] && continue
    keep_packages+=("$package")
  done < "$aur_packages_file"
  
  # Находим пакеты для удаления
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
  
  if [[ ${#to_remove[@]} -eq 0 ]]; then
    print_colored $GREEN "✅ Старые пакеты для удаления не найдены"
  else
    print_colored $YELLOW "Найдено старых пакетов для удаления: ${#to_remove[@]}"
    echo ""
    printf '   %s\n' "${to_remove[@]}"
    echo ""
    
    if confirm "Удалить эти пакеты?"; then
      for pkg in "${to_remove[@]}"; do
        rm -f "$aur_repo_dir/$pkg"
        print_colored $GREEN "🗑️  Удален: $pkg"
      done
      echo ""
      update_repository
    fi
  fi
  
  echo ""
  read -p "Нажмите Enter для возврата в меню..."
}

# Информация о пакете
package_info_interactive() {
  show_header
  print_colored $BLUE "ℹ️ Информация о пакете"
  echo ""
  
  local package=$(read_input "Введите имя пакета")
  
  if [[ -z "$package" ]]; then
    print_colored $RED "❌ Имя пакета не может быть пустым"
    read -p "Нажмите Enter для возврата в меню..."
    return
  fi
  
  echo ""
  print_colored $BLUE "📦 Информация о пакете: $package"
  echo ""
  
  # Проверяем в списке
  if grep -q "^$package$" "$aur_packages_file"; then
    print_colored $GREEN "✅ Пакет в списке для сборки"
  else
    print_colored $YELLOW "⚠️  Пакет НЕ в списке для сборки"
  fi
  
  # Проверяем локальную версию
  local local_pkg=$(find "$aur_repo_dir" -name "${package}-*.pkg.tar.zst" -type f | head -1)
  if [[ -n "$local_pkg" ]]; then
    local pkg_size=$(du -h "$local_pkg" | cut -f1)
    print_colored $GREEN "📁 Локальная версия: $(basename "$local_pkg") ($pkg_size)"
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
  
  echo ""
  read -p "Нажмите Enter для возврата в меню..."
}

# Главный цикл интерфейса
main_interface() {
  while true; do
    show_main_menu
    
    local choice=$(read_input "Введите номер действия")
    
    case $choice in
      1)
        list_packages_interactive
        ;;
      2)
        add_packages_interactive
        ;;
      3)
        remove_packages_interactive
        ;;
      4)
        build_packages_interactive
        ;;
      5)
        build_settings_interactive
        ;;
      6)
        setup_pacman_interactive
        ;;
      7)
        clean_old_packages_interactive
        ;;
      8)
        package_info_interactive
        ;;
      9)
        update_repository_interactive
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

# Основная функция
main() {
  # Настройка и проверки
  setup_directories
  check_yay

  # Блокировка для предотвращения одновременного выполнения
  exec 9>"$lock"
  if ! flock -n 9; then
    print_colored $RED "❌ Другой экземпляр скрипта уже выполняется"
    exit 1
  fi

  # Если нет параметров - запускаем интерактивный режим
  if [[ $# -eq 0 ]]; then
    main_interface
  else
    # Оставляем возможность запуска с параметрами для автоматизации
    print_colored $YELLOW "⚠️  Режим с параметрами не поддерживается в новой версии"
    print_colored $BLUE "Запустите скрипт без параметров для интерактивного режима"
    exit 1
  fi
}

# Запуск основной функции
main "$@" 