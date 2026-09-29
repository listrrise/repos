# dinapenis — Dynamic Island + виджеты для iOS 12–15

**Sileo-репозиторий:** `https://listrrise.github.io/repos/`

## Состав (v0.2.0)
- **Остров**: пилюля 126×37, спринг-анимация, компактный режим
  (иконка + waveform/пульс), Now Playing, звонки через CallKit.
- **Свайпы по острову**: влево — предыдущий трек, вправо — следующий
  (приватный MediaRemote через dlopen, публичный SDK собирается).
  Тап — раскрыть/схлопнуть.
- **Виджеты домашнего экрана** (стиль iOS 16): часы, батарея, музыка
  (тап — пауза/играть). Видны только дома, тапы мимо карточек уходят иконкам.
- **Настройки**: «Настройки → dinapenis» (остров, свайпы, виджеты, анимация).

## Структура
```
├── tweak/    # DinaPenis (остров)
├── widgets/  # DinaWidgets (виджеты, только SpringBoard/домашний экран)
├── prefs/    # панель настроек + иконка-капсула
├── index.html  # страница репо с вкладками iOS 12–15 / 15+ / 12+ / Any
└── .github/workflows/build.yml  # CI: rootful+rootless .deb → gh-pages
```

## Сборка локально (Theos)
```bash
export THEOS=~/theos
make package            # rootful
make package THEOS_PACKAGE_SCHEME=rootless   # rootless
```

## Ограничения
- Виджеты перекрывают верхний ряд иконок (как у iOS 14 их не раздвигаем, v1).
- Таймеры/AirPods/зарядка в острове — нет (приватные фреймворки по версиям).
