# Marta Thumbnail View

Thumbnail View для [Marta](https://marta.sh/): нативный Lua/Objective-C плагин, который добавляет Finder-like плиточный режим с превью прямо внутри окна Marta.

## Возможности

- Кнопка `View` в нижней action bar Marta.
- Хоткеи `Cmd+2` и `F3` для переключения List/Thumbnail View.
- Thumbnail grid внутри активной панели Marta, без отдельного внешнего окна.
- Выделение мышкой, `Cmd`/`Shift`-выделение, Enter/double-click open.
- Space открывает системный Quick Look preview.
- Escape снимает выделение, не закрывая thumbnail view.
- Превью через macOS `QuickLookThumbnailing`, включая изображения, PDF/текстовые превью, MP4 и другие форматы, которые умеет Finder.
- Маленький слайдер размера thumbnail в строке статуса: 80-150%, шаг 10%, дефолт 80%.
- Запоминание view mode отдельно для каждой папки.
- Сортировка в thumbnail view по видимым колонкам `Name`, `Extension`, `Size`, `Modified`.
- Опциональная колонка `Extension` для сортировки по типу/расширению файла в list view.

## Требования

- macOS 11 или новее.
- Marta 0.8.2.
- Homebrew.
- Xcode Command Line Tools для сборки native-библиотеки.

Если Command Line Tools еще не установлены:

```bash
xcode-select --install
```

## Установка Marta через Brew

```bash
brew install --cask marta
```

Проверь, что Marta установилась:

```bash
open -a Marta
```

После первого запуска Marta создаст пользовательскую папку настроек:

```text
~/Library/Application Support/org.yanex.marta
```

## Установка плагина

Закрой Marta, затем:

```bash
git clone https://github.com/specblades/marta-thumbnail-view.git
cd marta-thumbnail-view
./install.sh
```

Скрипт:

- скопирует плагин в `~/Library/Application Support/org.yanex.marta/Plugins/thumbnail-viewer`;
- сделает backup предыдущей версии, если она уже была установлена;
- соберет `libmartathumbs.so` из `thumbnail-viewer/martathumbs.m`;
- снимет quarantine-атрибуты macOS с файлов плагина.

Если Marta установлена не в `/Applications/Marta.app`, передай путь через переменную:

```bash
MARTA_APP="/path/to/Marta.app" ./install.sh
```

Если universal-сборка не проходит на твоей машине, можно собрать только под текущую архитектуру:

```bash
ARCHS="$(uname -m)" ./install.sh
```

## Подключение кнопки, хоткеев и колонки

Плагин добавляет action:

```text
com.csaturnus.marta.thumbnailviewer.open
```

Чтобы Marta показала кнопку и хоткеи, нужно добавить настройки в:

```text
~/Library/Application Support/org.yanex.marta/conf.marco
```

Готовый пример лежит в [`config.snippet.marco`](config.snippet.marco).

Если `conf.marco` почти пустой, можно использовать такой вариант:

```marco
behavior {
    layout {
        showActionBar true
    }

    table {
        defaults {
            columns "extension:53,>size:59,modified:99"
        }
    }
}

setup {
    actionBar [
        "core.open.with"
        {id "com.csaturnus.marta.thumbnailviewer.open" title "View"}
        "core.edit"
        "core.copy"
        "core.move"
        "core.rename"
        "core.new.directory"
        "core.delete"
    ]
}

keyBindings {
    "F3" "com.csaturnus.marta.thumbnailviewer.open"
    "Cmd+2" "com.csaturnus.marta.thumbnailviewer.open"
}
```

Если в `conf.marco` уже есть секции `behavior`, `setup` или `keyBindings`, не дублируй их целиком. Лучше перенеси только нужные строки:

- в `setup.actionBar` добавь `{id "com.csaturnus.marta.thumbnailviewer.open" title "View"}`;
- в `keyBindings` добавь `"Cmd+2" "com.csaturnus.marta.thumbnailviewer.open"` и, если нужно, `"F3" "com.csaturnus.marta.thumbnailviewer.open"`;
- в `behavior.table.defaults.columns` добавь `extension:53`, если нужна колонка `Extension`.

После изменения конфига перезапусти Marta:

```bash
osascript -e 'tell application "Marta" to quit'
open -a Marta
```

## Использование

- `Cmd+2` или кнопка `View` переключает текущую папку между List и Thumbnail View.
- `F3` делает то же самое, если ты добавил этот key binding.
- Space открывает Quick Look для выбранного файла.
- Escape снимает выделение.
- Слайдер справа в status row меняет размер thumbnail.
- Выбранный режим запоминается отдельно для каждой папки.

## Обновление

```bash
cd marta-thumbnail-view
git pull
./install.sh
```

После обновления перезапусти Marta.

## Удаление

```bash
./uninstall.sh
```

Удалить плагин вместе с сохраненными настройками размера и view mode:

```bash
./uninstall.sh --prefs
```

После удаления вручную убери из `conf.marco`:

- action bar кнопку `com.csaturnus.marta.thumbnailviewer.open`;
- key bindings `Cmd+2`/`F3`;
- колонку `extension:53`, если она больше не нужна.

## Где хранятся настройки

Плагин сохраняет пользовательские настройки через `NSUserDefaults` Marta:

```text
com.csaturnus.marta.thumbnailviewer.folderModes.v1
com.csaturnus.marta.thumbnailviewer.cellWidth.v2
```

Сбросить их можно так:

```bash
defaults delete org.yanex.marta com.csaturnus.marta.thumbnailviewer.folderModes.v1
defaults delete org.yanex.marta com.csaturnus.marta.thumbnailviewer.cellWidth.v2
```

## Troubleshooting

Посмотреть ошибки Marta за последние несколько минут:

```bash
/usr/bin/log show --last 5m --style compact --predicate 'process == "Marta"'
```

Если сборка не видит `clang`:

```bash
xcode-select --install
```

Если Marta стоит не в `/Applications`:

```bash
MARTA_APP="/path/to/Marta.app" ./install.sh
```

Если universal-сборка не проходит:

```bash
ARCHS="$(uname -m)" ./install.sh
```

## Ограничения

Это плагин, а не патч самой Marta. Он не меняет `/Applications/Marta.app` и не заменяет внутренний официальный display mode приложения. Thumbnail View реализован как нативный overlay внутри окна Marta и синхронизируется с активной панелью через доступный Lua API.

Практически это работает как отдельный view mode, но если Marta поменяет внутреннюю структуру окна, таблицы или plugin API, native-слой может потребовать адаптации.
