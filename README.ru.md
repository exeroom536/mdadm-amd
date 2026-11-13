# mdadm-amd

**Массивы AMD RAIDXpert2 в Linux через штатный md ядра — без блоба `rcraid`.**

[English](README.md) · [Установка](docs/install.md) · [Работа с массивами](docs/usage.md) ·
[Проверки](docs/testing.md) · [Формат](docs/format.md)

AMD RAIDXpert2 («RAIDCore») — RAID, встроенный в чипсеты AMD (X399, X570, X670, X870…). Массивы создаются в меню
BIOS или драйвером для Windows, метаданные на дисках не документированы; для Linux у AMD есть только `rcraid` —
внешний бинарный модуль. Здесь **mdadm** научен этому формату (`--metadata=amd`) так же, как он работает с Intel
IMSM: массивы ведёт md ядра, диски остаются на штатных `ahci`/`nvme`, а `mdmon` пишет метаданные туда, где их ждут
BIOS и Windows.

> [!WARNING]
> **Экспериментально.** mdadm-amd пишет метаданные RAID, и ошибка может стоить массива. Сначала бэкап и пробы на
> свободных дисках; никогда не загружайте `rcraid` на те же диски одновременно. Проверено на одной плате AMD.

## Возможности

- **Сборка и работа** массивов, созданных BIOS и Windows: Volume, RAID0, RAID1, RAID10, RAID5 и RAIDABLE, на SATA
  и NVMe; записи Legacy (диски без RAID) сохраняются как есть.
- **Создание** контейнеров и томов, которые меню BIOS и драйвер Windows показывают как Normal.
- **mdmon** ведёт состояние томов, инициализирует их и пересобирает на резервы или вернувшийся диск так же, как
  драйвер AMD; прерванная пересборка после перезагрузки продолжается с того места, где остановилась.
- **Миграция** RAIDABLE в RAID1, как у AMD.
- **Загрузка с тома**: mkinitcpio, initramfs-tools и dracut, с чистым выключением корневого тома.
- **Карта md (write-intent bitmap)** для RAID1, RAID10 и RAID5: после аварии пересинхронизируется только то, что
  писалось.
- **Починка** записи Legacy системного диска, которую ломает меню BIOS.

## Быстрый старт

Сборка и установка на Arch Linux, Debian и Ubuntu, Fedora, RHEL и производных, openSUSE —
[docs/install.md](docs/install.md). На Arch Linux:

```sh
sudo pacman -S --needed base-devel git
git clone https://github.com/exeroom536/mdadm-amd.git
cd mdadm-amd/packaging/arch
cp ../../mdadm/mdadm-amd.patch ../dkms/* .
makepkg -s
sudo pacman -U mdadm-amd-[0-9]*.pkg.tar.zst
```

Массивы из BIOS собирает udev при загрузке; вручную — `sudo mdadm --assemble --scan`. Новый набор дисков и RAID1
на нём:

```sh
sudo mdadm --create /dev/md/amd0 --metadata=amd --raid-devices=4 /dev/sd[abcd] --run
sudo mdadm --create /dev/md/data --level=1 --raid-devices=2 --size=100G /dev/md/amd0
```

Резервы, RAIDABLE, карта md, отказ диска, загрузка — в [docs/usage.md](docs/usage.md). Документация на английском,
кроме описания формата ([docs/format.md](docs/format.md), у каждого утверждения — источник).

## Планы

- [x] Сборка, работа и создание томов Volume, RAID0, RAID1, RAID10, RAID5 и RAIDABLE
- [x] `mdmon`: инициализация, пересборка на резервы и вернувшиеся диски, выделенные и глобальные резервы
- [x] Загрузка с тома (mkinitcpio, initramfs-tools, dracut)
- [x] Карта md (write-intent bitmap); миграция RAIDABLE → RAID1
- [ ] Запускать том, не нужный для загрузки, который остался `inactive` после загрузки без диска
- [ ] Правки ядра для карты md и TRIM на 6.18 и на 7.0 и новее, модулями DKMS (сейчас — Linux 7.3.1–7.3.3)
- [ ] Другие миграции AMD: расширение, смена уровня и размера полосы
- [ ] Распознавать XFS, btrfs, LUKS и LVM на диске при `--add` и `--create` (ext2/3/4 и ReiserFS — уже)

## Как сделано

Код, тесты и заметки о формате написал **Claude Opus 5.5** (модель ИИ Anthropic, через Claude Code); весь код затем
отдельным проходом проверил **Claude Fable 5.2**, он же написал исправления этого прохода; проверки на железе тоже
вели модели. Код не просматривал ни один человек. В каждом патче серии сказано, какие модели его написали.

Формат изучен ради совместимости — по метаданным своих дисков, модулям прошивки своей платы и открытому дампу X399;
раскладка части структур сверена с отладочной информацией (DWARF) Linux SDK AMD, как у
[joeytroy/amd-raid-driver](https://github.com/joeytroy/amd-raid-driver). Код AMD не копировался. Основание —
исключения для совместимости (ГК РФ ст. 1280 п. 2, директива ЕС 2009/24/EC ст. 6, DMCA §1201(f)).

## Лицензия

GPL-2.0-or-later ([LICENSE](LICENSE)), как у mdadm. `util-linux/amd_raid.c` — LGPL-2.1-or-later, как у libblkid.
`test-data/x399-raid10-plaidpiper/` — CC0 1.0.
