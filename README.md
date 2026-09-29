# dinapenis — Dynamic Island для iOS 12–15

Остров как на iPhone 14 Pro: чёрная пилюля по центру верха экрана,
раскрывается карточкой при музыке и звонках.

**Sileo-репозиторий:** `https://listrrise.github.io/repos/`

## Структура
```
├── Makefile        # aggregate: tweak + prefs
├── control
├── tweak/          # сам твик (SpringBoard)
├── prefs/          # панель в Настройках
├── index.html      # страница репозитория
├── CydiaIcon.png   # иконка репозитория
└── .github/workflows/build.yml  # сборка .deb + публикация в gh-pages
```

## Что умеет
- Пилюля 126×37 поверх всего, спринг-анимация (damping 0.72).
- Компактный режим: иконка + живая waveform / пульс звонка.
- Now Playing (название, артист, обложка), звонки через CallKit.
- Тап — раскрыть/схлопнуть, вибрация, авто-схлоп через 5–6 сек.
- Настройки в «Настройки → dinapenis», применяются на лету.

## Сборка локально (Theos)
```bash
export THEOS=~/theos
make package            # rootful (checkra1n/unc0ver)
make package THEOS_PACKAGE_SCHEME=rootless   # palera1n/Dopamine
```

## Как работает репозиторий
Каждый пуш в `main` запускает Action: сборка rootful + rootless `.deb`
на macOS-раннере с Theos, генерация `Packages`/`Release` и деплой
в ветку `gh-pages`. Sileo-источник: `https://listrrise.github.io/repos/`.
