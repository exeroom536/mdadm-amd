# Формат метаданных AMD RAIDXpert2 — что известно

Пометки источника (пути `notes/…`, `references/…`, `firmware/…`, `dumps/…` и `tools/…`, кроме
`tools/amdraid_dump.py` и `tools/amdraid_fix_legacy.py`, — из рабочего каталога автора, в этот репозиторий не входят):
- **[B]** — отладочная информация DWARF в `rcblob.x86_64` 9.3.3 (ядро RAIDCore из Linux SDK AMD, файл из `marcofortina/rcraid-dkms`, лежит в `references/rcblob-9.3.3/`, SHA256 `f0527abf…`; сборка 9.3.3-00122, **происхождение не подтверждено** — в пакетах Lenovo её нет; проверяемый официальный 9.3.3-00302 с DWARF — `references/lenovo-raid-linux/l2rad0005da.zip`, сверить типы). Имена структур, полей, значения перечислений. Выборка — `ondisk-structs.txt`, всё — `dwarf-types.txt` (выгрузки типов, в репозиторий не входят). Флагов (макросы `#define`) в DWARF нет;
- **[D:адрес]** — наш разбор `RAIDCoreDxe` из BIOS 1.A93 (движок `9.3.3-00277`), Ghidra 12.2 + дизассемблер; адрес — RVA функции. Выгрузка: `firmware/1A93/ghidra/RAIDCoreDxe-1A93.c`, функция — `tools/fn.sh <адрес>`;
- **[J]** — joeytroy/amd-raid-driver (`references/joeytroy-REVERSE_ENGINEERING.md`, коммит `9d91d6899bfa`; разбор `rcraid.sys` + проверка на TRX50, только NVMe);
- **[R:имя]** — код `rcblob.x86_64` 9.3.3 (Ghidra, функции с именами из символов): выгрузка `references/rcblob-9.3.3/ghidra/rcblob.x86_64.c`, функция — `tools/fn.sh <имя> references/rcblob-9.3.3/ghidra/rcblob.x86_64.c`;
- **[X]** — **настоящие дампы**: [PlaidPiper/x399-raidcore-fixtures](https://github.com/PlaidPiper/x399-raidcore-fixtures) (CC0, коммит `91c8d82b`), RAID10 2×2 из 4 SATA WD 10 ТБ, ASUS Zenith Extreme X399, массив создан в BIOS, в работе под Windows; LBA `0x5000…0x5FFF` каждого участника. Копия: `dumps/external/x399-raid10-plaidpiper/`, разбор — `tools/amdraid_dump.py --first-lba 0x5000 --ring <файл>`;
- **[Q]** — **эмуляция**: настоящий RAIDCoreDxe 9.3.3-00277 из прошивки MSI 1.A93 в QEMU+OVMF с подменой PCI ID контроллеров (`tools/qemu/`), диски — образы;
- **[A]** — **наш дамп**: ASRock X670E Pro RS (BIOS 3.50), RAID0 «prod» из двух Samsung 980 PRO 1 ТБ (NVMe, `1022:b000`), создан в BIOS; плюс Legacy-диск ADATA с Windows. `dumps/2026-10-28-asrock-x670e-raid0/` (LBA 0…0x5FFF, служебная область тома, хвост диска; README там же);
- **[F]** — прочее из образа BIOS (строки, IFR); **[P]** — наблюдения на exeroom-pc; **?** — гипотеза.

**Проверено на настоящих метаданных [X]** (4 диска, всё сошлось): сумма `RC_MetaData`, `RC_ConfigCommit` и всех 48 пакетов кольца; `CommittedChecksum` = `Checksum` живого пакета; серийный номер `0x859010220000` (массив в работе под Windows — значит, и Windows-драйвер пишет его же); раскладки PD, LD, элементов; `PreviousConfigPacketOffset`; положение пакета в кольце своё у каждого диска; зеркальные пары RAID10 — соседние элементы. Плюс [J] на NVMe: поля LD для RAID0/RAID1, UserDataOffset.

**[A] (NVMe RAID0, AM5, другой производитель платы) подтвердил всё то же**, а также: MBR с разделом `0x82` от `0x3F` и `RC_MetaData.MBRChecksum` = сумма LBA 0; RAID0 = First 2 × Second 1, ёмкость = Σ `UserDataSpace.Size`; кольцо переполнялось (341 пакет, номер 5060) — запись по кругу; журнал фоновой проверки в `AllocatedSpace + 2` с суммой; в конце диска за `AllocatedSpace` метаданных нет. Не проверено: Initialize целиком, RAID5/6, деградация.

[B] и [D] получены независимо (типы из Linux-блоба и код UEFI-драйвера) и **совпали** во всех полях ниже, где стоят обе пометки.

## Карта диска-участника

LBA — 512-байтные секторы от начала диска.

| LBA | Что | Источник |
|---|---|---|
| `0` | MBR: один раздел тип **`0x82`**, начало `0x3F`, размер = u32 ёмкости; подпись `0x1B8` случайная; `0x55AA` | [D:16e28] (Initialize) |
| `0`…`0x9FFF` | при Initialize зануляется (20 МиБ); **последние `0xA000` секторов диска — тоже** (у SATA одной командой записи нулей, у NVMe кусками по 0x10) | [D:16e28] |
| `0x4F80`…`0x4FFD` | 0x7E секторов байтом **`0xAF`** — пишет меню (`FUN_0001d0e4`, читает `FUN_0001ded8`) до записи конфигурации; на распознавание диска не влияет (?), `super-amd.c` повторяет | [D:1d0e4, 1ded8], [Q, снимок `01`] |
| `0x5000` | **`RC_MetaData`** — метка диска, 1 сектор | [B], [D:16e28, 29128, 24e88] |
| `0x5001` | **`RC_ConfigCommit`** — блок фиксации, 1 сектор | [B], [D:28388, 24f10], [J] |
| `0x5800`…`0x5FFF` | **кольцо пакетов конфигурации** (config ring), 0x800 секторов | [B], [D:16e28, 27fb4], [J] |
| `0x6000`…`0xFFFFF` | не используется: на [A] нули или остатки прежних данных | [A] |
| `0x100000`…`0x104FFF` | служебная область тома (`AllocatedSpace` до `UserDataSpace`), см. ниже | [R], [X], [A] |
| `0x105000` (=1069056) | начало данных участника (`UserDataSpace.SectorOffset` элемента) | [J], [P] |

- В PD есть `StartMetaDataSpace` и `EndMetaDataSpace` (`RC_Space_LE`), но UEFI их не заполняет (нули) [B], [D:28ae8], [X], [A]. За концом `AllocatedSpace` (= `Capacity` PD = размер раздела MBR) до конца диска — нули [A]: второй копии метаданных нет.
- Блок `RC_MetaData` при Initialize собирается в том же буфере, где перед этим был MBR, — в `Reserved` могут остаться байты MBR (`0x1B8`…`0x1FF`); сумма их покрывает. ? [D:16e28]

## Контрольная сумма (общая для всех структур)

**Не CRC.** Строки `CRC Error` и `CRC32C` в RAIDCoreDxe — из библиотек EDK2 (`EFI_CRC_ERROR`, iSCSI в DevicePath). [F]

`FUN_0000698c(buf, len, out)` — XOR 64-битных слов с перестановкой 16-битных половинок [D:698c, сверено по дизассемблеру]; тот же алгоритм у [J] из `rcraid.sys` (`FUN_1400014ec`), их драйвер проверяет им `RC_MetaData` на настоящих дисках:

```
acc = 0
for i in 0 .. len/8 - 1:          # остаток < 8 байт не считается
    w = u64le(buf + 8*i)
    a = w & 3;  b = acc & 3       # номера 16-битных дорожек
    if a == b: a = i & 3; b = (i + 1) & 3
    поменять местами 16-битные дорожки a и b в w
    acc ^= w
результат = acc
```

| Структура | Поле суммы | Что покрывает | Источник |
|---|---|---|---|
| `RC_MetaData` | `Checksum` `+0x00` | `+0x08`…`+0x1FF` | [B], [D:24e88], [J]+железо |
| `RC_ConfigCommit` | `Checksum` `+0x00` | `+0x08`…`+0x1FF` | [B], [D:24f10, 28388] |
| пакет конфигурации (`RC_ConfigPacketHeader` + записи) | `Checksum` `+0x00` | `+0x0C`…`PacketSize` — весь пакет, кроме `Checksum` и `PreviousConfigPacketOffset` | [B], [D:2b908, 28ae8, 1d68c] |
| MBR (LBA 0) | `RC_MetaData.MBRChecksum` | весь сектор 0x200 | [B], [D:16e28] |
| `RC_TransformLogStruct_LE` (журнал миграции/пересборки) | `Checksum` `+0x00` | ? | [B] |

## Идентификаторы

- `RC_DeviceIdentifier_LE` (0x10): `u64 DeviceID`, `RC_Handle_LE DeviceHandle` (`u16 Internal` — номер порта/слота, `u16 RoutingPath`), `u32 Reserved`. Встречается в PD, LD (`ClusterID`, `ID`, `InvalidateID`), элементе, ссылках. [B]
- **DeviceID диска — не случайный: хеш серийного номера** [D:19904, 6ae0; проверено на 11 дисках дампов и на стенде 03.11]. `+0x18` записи диска = H(поле серийного номера 20 байт, как его отдаёт диск — с пробелами: у HDD слева, у QEMU/NVMe справа), `+0x20` = H(обрезанный номер + NUL); Initialize в меню пишет `RC_MetaData.DeviceId = +0x18` [D:16e28], при совпадении с занятым — случайные 48 бит (FUN_000199cc → FUN_00019aa4). H [D:6ae0]: 20 байт + 12 × `'t'`, два 31-битных регистра `A = B = 0x7fffffff`, по битам от младшего: `A |= 0x80000000`, если бит ≠ `((A>>28)^A)>>2 & 1`, затем `A >>= 1`; `B` — то же с `((B>>26)^B)>>3`; итог `A + (B<<32)` (`tools/amdraid_serial_id.py`). **Меню ищет PD элемента только по этому ключу** (FUN_00019b58, FUN_00021bb0 → handle элемента [D:194f8]): при другом ID диск — «New», «Associated Array(s)» пуст, свободно 0, у тома «Array Capacity 0.0 KB» (FUN_0001174c: ёмкость 0, если FUN_00006bdc не нашёл ни одного диска тома); сам том при этом собирается и грузится. mdadm с 03.11 пишет DeviceID = H(серийный номер) (`amd_disk_id`). **ID тома** — случайные 48 бит [D:19aa4]; у [X] — 64-битные `0x6abf213a77580dbb` (Windows/старая прошивка).
- **Серийный номер контроллера (хоста) в UEFI = константа `0x0000859010220000`** (`mov [ctx+0xE8], 0x859010220000` по адресу `0x1700`; декомпилятор запись потерял). Пишется в `RC_ConfigPacketHeader.ModifierSerialNumber`, в `RC_ConfigCommit.LastModifierSerialNumber` и `LastOnlineSerialNumber`, в псевдо-PD контроллера. Если `LastOnlineSerialNumber` ≠ своему — конфигурация **чужая** (`RC_CONFIG_FOREIGN`). [D:0x1700, 2dcf8, 28810]
- На [X] (BIOS + Windows) везде `0x859010220000` — писать его же.

## `RC_MetaData` (LBA 0x5000, 0x200 байт)

| Смещение | Тип | Поле [B] | Значение / смысл | Источник |
|---|---|---|---|---|
| `+0x00` | u64 | `Checksum` | сумма `+0x08…+0x1FF` | [B], [D:24e88] |
| `+0x08` | u64 | `RCIdent` | `0x65726F4344494152` = ASCII **`RAIDCore`** | [B], [D:24e88] |
| `+0x10` | u64 | `DeviceId` | DeviceID диска; 0 → драйвер выдаёт новый | [B], [D:29128] |
| `+0x18` | u64 | `ConfigCommitOffset` | `0x5001` | [B], [D:16e28] |
| `+0x20` | u64 | `ConfigRingOffset` | `0x5800` | [B], [D:16e28] |
| `+0x28` | u32 | `ConfigRingSize` | `0x800` секторов (у [J] сначала был принят за размер полосы) | [B], [D:16e28] |
| `+0x2C` | u32 | `Version` | **`0x30000`** (проверяется) | [B], [D:24e88] |
| `+0x30` | u32 | `Features` | при Initialize `0x1C`; младшие 16 бит → `RC_PhysicalDeviceOnDisk.Features` | [B], [D:16e28, 29128] |
| `+0x34` | u32 | `SpareInfo` | → `RC_PhysicalDeviceOnDisk.SpareInfo` | [B], [D:1d68c] |
| `+0x38` | u64 | `MBRChecksum` | сумма LBA 0; если 0 — RC_ReadMBR проверяет тип раздела `0x82`. **Проверено в эмуляции** (RAIDCoreDxe в QEMU, `tools/qemu/`): при несовпадении диск считается не инициализированным — массив не собирается | [B], [D:16e28, 296cc], [Q] |
| `+0x40` | | `Reserved[112]` | | [B] |

## `RC_ConfigCommit` (LBA 0x5001, 0x200 байт)

| Смещение | Тип | Поле [B] | Смысл | Источник |
|---|---|---|---|---|
| `+0x00` | u64 | `Checksum` | сумма `+0x08…+0x1FF` (у [J] — «время записи»: неверно) | [B], [D:28388] |
| `+0x08` | u32 | `ConfigPacketOffset` | LBA живого пакета (1…0x6000, иначе считается `0x5800`) | [B], [D:2dcf8] |
| `+0x0C` | u32 | `PacketSize` | длина пакета, байт (1…0xFFFFF) | [B], [D:24f10] |
| `+0x10` | u64 | `CommittedChecksum` | `Checksum` живого пакета (у [J] — «timestamp») | [B], [D:28e98, 1ded8] |
| `+0x18` | u64 | `GenerationNumber` | номер конфигурации; берётся максимум по дискам, у кого меньше — устарел (`RC_CONFIG_LOCAL_OUTDATE`) | [B], [D:2dcf8] |
| `+0x20` | u64 | `LastModifierSerialNumber` | серийный номер контроллера, писавшего конфигурацию | [B], [D:1ded8] |
| `+0x28` | u64 | `LastOnlineSerialNumber` | серийный номер контроллера, где диск был в работе; ≠ свой → чужая | [B], [D:2dcf8] |
| `+0x30` | u64 | `PacketNumber` | счётчик записей на **этот** диск (+1 каждый раз) | [B], [D:28388] |
| `+0x38` | u32 | `CommittedBy` | 0 (RC-путь UEFI) или 1 (меню HII) | [B], [D:28388, 1ded8] |

**Выбор живой конфигурации** [D:2dcf8]: среди RAIDCORE_DISK с валидным блоком фиксации и `LastOnlineSerialNumber` = своему побеждает наибольший `GenerationNumber` (стартовое значение — текущий номер в памяти драйвера), его `CommittedChecksum` — эталон; так же выбирает `super-amd.c`. Меню HII при Initialize/Hot Spare пишет конфигурацию со своим, **сброшенным** номером (на стенде 20 → 3, 4; счётчики записей — с 1) [Q, снимки `10`, `11`] — диск, пропустивший такую запись, по этому правилу потом победил бы и у AMD. Отступать от правила нельзя (Linux и BIOS разойдутся).

Флаги диска при выборе конфигурации [D:2dcf8, 2df90]: `|2` блок валиден, `|1` нет; `|4` устаревший `GenerationNumber`, `|8` актуальный; `|0x20` `CommittedChecksum` совпал с выбранным пакетом, `|0x10` нет. Типы конфигураций — `RC_ConfigType` (`0x1357` NV, `0x1358` LOCAL, `0x1359` FOREIGN, `0x135B` LOCAL_CONFLICT, `0x135C` FOREIGN_CONFLICT, `0x135E` LOCAL_OUTDATE). [B], [D:2a194]

## Кольцо пакетов конфигурации (LBA 0x5800, 0x800 секторов)

- Каждое изменение пишет **полный пакет** сразу за предыдущим: `start = прежний + ceil(прежний PacketSize / 512)`; если меньше `0x5800` — `0x5800`; если `start + PacketSize/512 > 0x6000` — **с начала, `0x5800`**. Старые пакеты остаются (у [J] — «поколения»). [D:27fb4, 28388], [J]
- Порядок записи (RC_UpdateConfig) [D:28e98]: собрать пакет → записать на все диски (RC_WriteAllConfigData) → `GenerationNumber` +1 → записать `RC_ConfigCommit` на все диски → сбросить кеши дисков.
- Пакет одинаков на всех дисках, кроме `PreviousConfigPacketOffset` (вне суммы): там LBA предыдущего пакета **этого** диска. [B], [D:27fb4]
- Живой пакет определяет только `RC_ConfigCommit`. Разбирать подряд всё кольцо нельзя — соберётся удалённый массив. [J]

### `RC_ConfigPacketHeader` (первые 0x200 байт пакета)

| Смещение | Тип | Поле [B] | Значение | Источник |
|---|---|---|---|---|
| `+0x00` | u64 | `Checksum` | сумма `+0x0C … PacketSize` | [B], [D:28ae8] |
| `+0x08` | u32 | `PreviousConfigPacketOffset` | LBA предыдущего пакета на этом диске | [B], [D:27fb4] |
| `+0x0C` | u64 | `HeaderKey` | **`0xE1E10000`** (проверяется) | [B], [D:24a54] |
| `+0x14` | u32 | `Version` | 1 | [B], [D:28ae8] |
| `+0x18` | u32 | `PacketSize` | длина пакета, кратна 512 | [B], [D:28ae8] |
| `+0x1C` | u64 | `ModifierSerialNumber` | серийный номер контроллера | [B], [D:28ae8] |
| `+0x24` | u32 | `PhysicalDeviceOffset` | `0x200` | [B], [D:24a54] |
| `+0x28` | u32 | `PhysicalDeviceSize` | 0x80 × (дисков + 1) | [B], [D:28ae8] |
| `+0x2C` | u32 | `LogicalDeviceOffset` | | [B] |
| `+0x30` | u32 | `LogicalDeviceSize` | | [B] |
| `+0x34` | u64 | `GenerationNumber` | **на 1 меньше**, чем в `RC_ConfigCommit` (пакет 53 → commit 54) | [B], [D:28e98], [X]; меню HII пишет равные [D:1d68c] |
| `+0x3C` | u32 | `WaitForAcceptConfigChange` | 0/1 | [B] |
| `+0x40` | u32 | `ControllerDeviceOffset` | записи `RC_ControllerDevice` | [B] |
| `+0x44` | u32 | `ControllerDeviceSize` | N × 0x88 | [B] |
| `+0x48` | u32 | `SEPDeviceOffset` | записи `RC_SEPDevice` | [B] |
| `+0x4C` | u32 | `SEPDeviceSize` | N × 0x40 | [B] |
| `+0x50` | | `Reserved[108]` | | [B] |

`PacketSize` = `0x200 + 0x80 × (PD + 1) + Σ PacketSize(LD) + 0x88 × N(ctrl) + 0x40 × (N(SEP) + 8)`, округлить вверх до 512. [D:24b8c]

Тип записи — первый u32, `RC_DeviceStructType`: `0x25BC` PHYSICAL_DEVICE, `0x25BD` LOGICAL_DEVICE, `0x25BE` CONTROLLER_DEVICE, `0x25BF` SEP_DEVICE, `0` — конец. [B]

### `RC_PhysicalDeviceOnDisk` (`0x25BC`, 0x80 байт)

Первая запись (`+0x200`) — **псевдо-PD самого контроллера** (`DeviceType = 0x1201` RAIDCORE_CORE, `DeviceID.DeviceID` = серийный номер, `Handle.Internal = 0xFFFF`). Дальше — по записи на диск. [D:28ae8, 1d68c]

| Смещение | Тип | Поле [B] | Значение | Источник |
|---|---|---|---|---|
| `+0x00` | u32 | `StructureType` | `0x25BC` | [B] |
| `+0x04` | 0x10 | `DeviceID` | DeviceID (= `RC_MetaData.DeviceId`), `Handle.Internal` — порт, `RoutingPath` = 1 (не физический порт: у второго HDD Handle 3, а меню пишет «Connected Port: 1»; MSI раздаёт Handle по порядку — XPG 1, HDD 2…5 [M]) | [B], [D:1d68c], [M] |
| `+0x14` | 4 | `PreviousHandle` | прежний порт | [B], [D:28ae8] |
| `+0x18` | u32 | `Devices` | | [B] |
| `+0x1C` | u64 | `Capacity` | ёмкость, секторов | [B] |
| `+0x24` | u32 | `DeviceType` | `0x1200` RAIDCORE_DISK, `0x1201` RAIDCORE_CORE, `0x1202` NOT_INITIALIZE, `0x1203` LEGACY, `0x1204` Promise | [B], [D:1d68c] |
| `+0x28` | u32 | `BusType` | `0x2000` LOCAL (`0x2001` CLUSTER); на [X] — 0 | [B], [D:1d68c], [X] |
| `+0x2C` | u32 | `DeviceState` | `0x3000` ONLINE, `0x3001` OFFLINE, `0x3002` SMARTERR, `0x3003` NEW, `0x3004` LOCKED. rcraid 9.3.2 (судья, 07.11): диск отказал на ходу — OFFLINE; отсутствует при старте драйвера — PD убран (как Windows); вернулся — ONLINE (`notes/rcraid-judge.md`) | [B], [Q-rcraid] |
| `+0x30` | u32 | `SpareInfo` | = `RC_MetaData.SpareInfo` | [B], [D:1d68c] |
| `+0x34` | 0x10 | `StartMetaDataSpace` | `RC_Space_LE` (u64 SectorOffset, u64 Size) | [B] |
| `+0x44` | 0x10 | `EndMetaDataSpace` | | [B] |
| `+0x54` | u32 | `Features` | младшие 16 бит = `RC_MetaData.Features` (`0x1C`); на [X] — `0x21ED001C` (у двух дисков и в `RC_MetaData`) | [B], [D:28ae8], [X] |
| `+0x58` | u32 | `PortType` | | [B] |
| `+0x5C` | | `Reserved[9]` | | [B] |

**Запись конфигурации самим RAIDCoreDxe при загрузке портит PD** [D:28e98, 28ae8], [Q, снимки `07`, `13`]: общий путь записи (`FUN_00028e98` ≈ `RC_UpdateConfig`) собирает пакет в обнулённом буфере функцией `FUN_00028ae8`, а она у записей PD заполняет только `PreviousHandle`, `Capacity`, `DeviceType`, `DeviceState`, `SpareInfo`, `Features` (младшие биты → `0x1C`), но **не `DeviceID`, `Handle` и `BusType`** (остаются 0); строку версии `"9.3.3-00277"` она копирует по смещению `+0x288` — в `DeviceID` PD 1. Меню HII (Initialize, Hot Spare) пишет через другой путь [D:1d68c] — там PD правильные. На стенде этот путь срабатывал при загрузке с отставшим диском (`07`) и с записанной пересборкой `RESTORE_SEGMENTS` (`13`); без трансформаций и отставших дисков прошивка при загрузке не пишет (`08`, `12`, `14`). Драйвер ОС AMD строит список PD по меткам дисков (`RC_BuildChangePhysicalDeviceList`); `super-amd.c` при нулевых `DeviceID` берёт ID/порт/шину/`Features` из ближайшего более раннего пакета того же кольца (`PreviousConfigPacketOffset`) с тем же списком PD (`amd_repair_pds`). **На железе [M]** (MSI X870E, 02.11): после загрузки в режиме RAID прошивка записала так конфигурацию 21 (4 HDD; тогда у Volume сменился State 0 → NORMAL), следующая загрузка без изменений — не писала; `amd_repair_pds` восстановил PD из кольца, BIOS принял наш пакет с полными PD (конфигурация 23). **На железе [M], 04.11:** две загрузки подряд с Critical-томами (элемент `0x30`), незавершённой `CREATE_REDUNDANCY` (тома меню 3/4) и — во второй — записанной mdmon пересборкой `RESTORE_SEGMENTS` на 81% (журнал трансформации `protect_start` 208001664, STARTED): прошивка **не писала** ни разу (commit 28 → пакет seq 27 до и после POST). На стенде (`13`) с `RESTORE_SEGMENTS` писала — ? чем отличается (там пересборка шла на резерв `0x100`, здесь — в слот своего вернувшегося участника; или отставший диск).


**Выделенный резерв и RAIDABLE** [Q 06.11, стенд на mdadm-dev2 (TCG), `dumps/2026-11-06-qemu-spares-raidable/` снимки 03, 04, 07, 11–13; `notes/agent-stand-spares.md`]:
- Выделенный резерв пишется **только в основную копию LD** (у тома с `TransformLink` = 1 — в первую): `SpareCount` (`+0x8C`) = n, `PacketSize` += 0x10·n; после ссылок на родителя (хост) — n записей `RC_DeviceIdentifier` (16 байт): `DeviceID` u64, порт PD u16, `RoutingPath` u16 = 1, резерв u32 = 0. Два резерва — в порядке назначения/портов (не различено). **Сам диск не помечен:** PD `SpareInfo` = 0, у метки `+0x34` = 0 (у глобального — 0x100). После перезагрузки стенда меню показывает «Dedicated Spare», прошивка при загрузке ничего не пишет. Снятие (Physical Disk Operations → Unassign Hot Spare) — `SpareCount` −1, запись убирается.
- В резерв годится только целиком свободный инициализированный диск («Ready», без элементов в LD), не Legacy; NVMe с другого контроллера — да; один диск — резерв только одного тома; выделенный резерв не предлагается в Create Array. Пункт активен и у RAID1 в состоянии Ready (State 0).
- RAIDABLE (`0x1BFB`) — один свободный «Ready»-диск целиком: LD 1×1, Parent 1, Spare 0, длина 0x250, одна копия (как Volume меню); State 0 → 0x200 со следующей записью; `LastOp` CREATE_REDUNDANCY, Transform 0; Cache 0xC0000000, Chunk 0, CTS 1; элемент alloc `0x100000 + (N−0x100000)` (до последнего сектора), data `0x105000 + (N−0x105000)`, `Capacity` = размер data. Размер в меню не задаётся. Windows (rcraid.sys) делает из него RAID1 миграцией `TRANSFORM_NORMAL` (`notes/rcraid-sys.md`).
- Порядок выбора резерва драйвером ОС: выделенный → распределённый → глобальный [rcraid.sys, `RC_SetupTransform`].
- **Назначение и снятие в ядре RAIDCore** [R: `RC_AssignSpare`, `RC_DeassignSpare` → `RC_RemoveSpare`, `RC_RemoveUnusableDedicatedSpares`, `RC_ManageGlobalSpare`, `RC_DeassignPhysicalDeviceGlobalSpare`]: выделенный — диск есть в таблице PD, не пустой ID, не `SMARTERR`, в сети, `RAIDCORE_DISK`, `SpareCount < SpareListSize` (4), не участник этого тома (`RC_DeviceAlreadyInRaidSet`), на том же контроллере, что первый найденный участник (`DevicePrivate[0x3c]`), если в `RC_GetFeatures()` нет бита 8 (меню на стенде этого не требует — NVMe для SATA-RAID1); уже в списке — успех без записи; добавляется в конец списка. **Целиком свободный диск требует только меню**, ядро — нет. `RC_RemoveUnusableDedicatedSpares`: у неаварийного тома убирает выделенные резервы с ёмкостью PD меньше наименьшего участника, у аварийного — без свободного промежутка размером с сегмент тома. Глобальный: снятие отказывает для `OFFLINE`/`UNKNOWN` диска; и назначение, и снятие переписывают метку (`RC_UpdateMetaData`) — `SpareInfo` метки, из которой BIOS заполняет PD. Один диск может быть выделенным резервом нескольких томов (ядро этого не запрещает).
- **Том на глобальном резерве** [R: `RC_CreateRaidArray` @00146860 — у диска проверяет только «в сети» (`RC_PhysicalDeviceOnLine` @0018cda0) и `RAIDCORE_DISK` (`RC_PhysicalDeviceInitialize` @0018cde0); `SpareInfo` в этом пути не читает и не пишет; бит 0x100 меняют только `RC_ManageGlobalSpare` @001672b0 → `RC_Assign/DeassignPhysicalDeviceGlobalSpare` @00190ed0/@00190d90, после каждого — запись метки], [D: меню томов из резервов не делает — у глобального резерва свой статус (`FUN_0000dc88`); участника с 0x100 показывает «Global Spare» — [HW] MSI после миграции на резерв]. Наш `-C` (с 08.11, `notes/agent-create-spare.md`) берёт глобальные резервы контейнера, как IMSM, и снимает роль — `SpareInfo 0` в PD и в метке, как у тома меню из дисков Ready; примут ли прошивка и Windows — не проверено.
- На стенде Initialize и Delete Array записали последний пакет с PD без ID (путь `FUN_00028ae8`), **на железе Delete — с правильными PD** (06.11 ~01:25, `dumps/2026-11-06-bios-del12-r1x3/`: пакеты 1, 2 с ID и `0x2900`) — расхождение не выяснено.

### `RC_LogicalDevice` (`0x25BD`, переменная длина)

`PacketSize` записи = `0x200 + 0x40 × FirstCount × SecondCount + 0x10 × (ParentCount + SpareCount)`. [D:6a80, 25f74]

| Смещение | Тип | Поле [B] | Значение / смысл | Источник |
|---|---|---|---|---|
| `+0x00` | u32 | `StructureType` | `0x25BD` | [B] |
| `+0x04` | u32 | `LogicalElementOffset` | `0x200` | [B], [D:25f74] |
| `+0x08` | u32 | `State` | `0x200` NORMAL, `0x201` CRITICAL (деградация), `0x202` OFFLINE, `0x203` OUTDATE, `0x204` LOCKED | [B] |
| `+0x0C` | u32 | `DeviceType` | `RC_LogicalDeviceTypes`, см. ниже | [B], [D:248ac] |
| `+0x10` | u32 | `TransformType` | `0` — нет; `0x5354` NORMAL, `0x5355` CREATE_REDUNDANCY (инициализация чётности/зеркала), `0x5356` CHECK_REDUNDANCY, `0x5357` COPY_SEGMENTS, `0x5358` RESTORE_SEGMENTS (пересборка?), `0x535B` CREATE_ZERO, … | [B] |
| `+0x14` | u32 | `LastOperation` | тот же набор | [B] |
| `+0x18` | u32 | `TransformState` | `0xA1A1` STARTED … `0xA1A6` COMPLETED, `0xA1A4` FAILED, … | [B] |
| `+0x1C` | 0x10 | `ClusterID` | | [B] |
| `+0x2C` | 0x10 | `ID` | ID тома (48-бит случайный) | [B], [D:2b908] |
| `+0x3C` | 0x10 | `InvalidateID` | | [B] |
| `+0x4C` | 4 | `PreviousHandle` | | [B] |
| `+0x50` | u64 | `Capacity` | ёмкость тома, секторов | [B], [J] |
| `+0x58` | u64 | `TransformProtectStart` | граница миграции/пересборки ? | [B] |
| `+0x60` | u64 | `GenerationNumber` | | [B] |
| `+0x68` | u32 | `Devices` | число участников | [B], [J] |
| `+0x6C` | u32 | `FirstCount` | ширина полосы (1…256) | [B], [J] |
| `+0x70` | u32 | `SecondCount` | число зеркал (1…64) | [B], [J] |
| `+0x74` | u32 | `ParentCount` | число ссылок на «родителей» после элементов (1…16); у тома первая — серийный номер контроллера | [B], [D:1d234] |
| `+0x78` | u32 | `TransformFlags` | | [B] |
| `+0x7C` | u32 | `TransformProtectSize` | | [B] |
| `+0x80` | u32 | `Cache` | кеш **драйвера AMD** (не дисков): `0x80000000` — «Read Cache» (упреждающее чтение), `0x40000000` — «Write Back Cache» (отложенная запись; справка меню: «may result in loss of data»); `0xC0000000` — оба, умолчание меню [X], [M]. Меню: Read 2/1, Write 4/3 (IFR, varstore 0x8020 +0x10/+0x11) → флаги запроса 8/4 → биты при создании LD [D:1fd20, 1d234]; список массивов выводит флаги как (R)/(W)/(R/W) [D:158d4]. У md своего кеша нет — в Linux поле не применяем, храним как есть | [B], [X], [D], [M] |
| `+0x84` | u32 | `Flags` | бит `0x10000000` влияет на флаги элементов | [B], [D:25f74] |
| `+0x88` | u32 | `TransformLogicalDeviceLink` | **1 — за этой записью идёт связанный LD** (цель трансформации); то самое «LD дважды» у [J] | [B], [D:28ae8, 28810] |
| `+0x8C` | u32 | `SpareCount` | число выделенных резервов (0…4), ссылки после родителей | [B], [D:249bc] |
| `+0x90` | u32 | `PacketSize` | длина записи | [B], [J] |
| `+0x94` | u32 | `TransformPercentDone` | | [B] |
| `+0x98` | u32 | `Attribute` | бит `4` — у тома ведётся битовая карта (`RC_FlushBitmap` обходит только такие); бит `0x100` влияет на выбор RMW в RAID5/6; [X]: `0x401`, во время проверки битовой карты `0x405` | [B], [R:RC_FlushBitmap, RC_DetermineRAID56StripeType], [X] |
| `+0x9C` | u32 | `LastRepairCount` | | [B] |
| `+0xA0` | u32 | `DistributedSpare` | | [B] |
| `+0xA4` | u32 | `PreferReadElement` | | [B] |
| `+0xA8` | u32 | `TaskPriority` | скорость задачи (`RC_GenDelay`): меню 0x14, `rcadm -p 1` 0x63 | [B], [R] (`notes/agent-init-rcraid.md`) |
| `+0xAC` | u32 | `ChunkSize` | секторов (0 у RAID0 по [J]) | [B], [J] |
| `+0xB0` | 32 байта | `DevicePrivate` | **имя тома**, ASCII с нулём (`Archives` на [X]) | [B], [X] |
| `+0xD0` | u32 | `ReferenceCount` | | [B] |
| `+0xD4`, `+0xDC` | u64 | `CopyFromID`, `CopyToID` | | [B] |
| `+0xE4` | u64 | `QsyncLogicalElementID` | | [B] |
| `+0xEC` | 0x10 | `QsyncAllocatedSpace` | | [B] |
| `+0xFC`, `+0x104` | u64 | `ColdDeviceID`, `HotDeviceID` | (RAIDTIER) | [B] |
| `+0x10C` | u32 | `TierMetadataPageCount` | | [B] |
| `+0x110` | u32 | `CacheTagSize` | индекс размера полосы на диск: 1/0 → 64 КБ, 2 → 128 КБ, 3 → 256 КБ (у [J] — chunk_index; в меню — «CacheTagSize») | [B], [J], [F] |
| `+0x114` | | `Reserved[59]` | | [B] |
| `+0x200` | | `ArraysStart`: элементы FirstCount × SecondCount по 0x40 (внешний цикл — First), затем ParentCount × 0x10, затем SpareCount × 0x10 (`RC_DeviceIdentifier_LE`) | [B], [D:25f74] |

`RC_LogicalDeviceTypes` [B] (у [J] часть названий неверна):

| Значение | Имя | Комментарий |
|---|---|---|
| `0x1BF5` | `RC_RAID50` | **RAID5** (FirstCount = 1, SecondCount = дисков) и RAID50 (FirstCount = число наборов); одна чётность [R:RC_DetermineRAID56StripeType] |
| `0x1BF6` | `RC_RAID10N` | общий «полоса × N зеркал»: RAID0 (First=N, Second=1), RAID1 (First=1, Second=2), RAID10 (First>1, Second=2) — [J] видел RAID0 и RAID1 |
| `0x1BF7` | `RC_VOLUME` | «Volume» (у [J] — RAID1: неверно) |
| `0x1BF8` | `RC_RAW_DEVICE` | при чтении отбрасывается [D:248ac] |
| `0x1BF9` | `RC_LEGACY_DEVICE` | **Legacy-диск** (не инициализированный, с обычными данными): LD на весь диск, `UserDataSpace` = 0 + весь размер; у самого диска метки `RAIDCore` нет — он описан только в метаданных RAID-дисков (PD с `DeviceType = 0x1203`) [A]. У [J] — «сырой LD на каждого участника»: это были их Legacy-диски |
| `0x1BFA` | `RC_RAID60` | **RAID6** (FirstCount = 1) и RAID60; две чётности, Q — EVENODD (у [J] — «RAID5»: неверно). **Ни одна платформа не включает** (маска уровней MSI `0x6b`; документы AMD 53987 ред. 3.30, release notes 9.3.3, Dell S150 A13, ASUS WRX90, Lenovo ST45 V3 — RAID6 нет; JOURNAL 05.11 ~18:10); mdadm такой том не собирает (с 05.11) |
| `0x1BFB` | `RC_RAIDABLE` | «RAIDABLE» (у [J] — RAID10: неверно) |
| `0x1BFC` | `RC_THIRD_PARTY_PROMISE` | |
| `0x1BFD` | `RC_RAIDTIER` | |

Проверка LD при чтении [D:248ac]: тип `0x1BF5…0x1BF7` или `0x1BF9…0x1BFB`; FirstCount 1…256, SecondCount 1…64, ParentCount 1…16, Devices ≠ 0, Capacity ≠ 0; длина ≠ расчётной — разбор останавливается [D:28810].

~~В UEFI обработчик ввода-вывода назначается только `0x1BF6`, у остальных — заглушка. [D:28810]~~ **Неверно для RAID5** [Q, 03.11]: на стенде RAID5 (0x1BF5, 3 диска, создан нашим mdadm, GPT+FAT) прошивка отдаёт BlockIo — UEFI Shell видит `FS1` на `Pci(0x8)/Unit(1)/HD(1,GPT…)` и читает файл. Volume (0x1BF7) — не проверено.

### `RC_LogicalElement_LE` (элемент тома, 0x40 байт)

| Смещение | Тип | Поле [B] | Смысл |
|---|---|---|---|
| `+0x00` | 0x10 | `ID` | DeviceID диска + Handle (порт; `RoutingPath` = 1) |
| `+0x10` | 0x10 | `AllocatedSpace` | выделенный экстент; [X]: `0x100000` + `0x48C300000` |
| `+0x20` | 0x10 | `UserDataSpace` | данные; [X]: `0x105000` + `0x48C2FB000` (начало на 0x5000 позже, размер на 0x5000 меньше) |
| `+0x30` | u32 | `Flags` | маска `0x4030` — элемент не используется для ввода-вывода (сбой/нет диска); `0x20` без `0x4010` — диск под подозрением, при записи сигналить ошибку [R:RC_Raid50LogicalToPhysical]; [X]: 0 |
| `+0x34` | | `Reserved[3]` | |

Меню считает экстенты в единицах 0x800 секторов (1 МиБ). [D:1d234]

**Служебная область тома** — первые 0x5000 секторов `AllocatedSpace` перед `UserDataSpace` (у каждого участника) [R], [X]:

| От `AllocatedSpace.SectorOffset` | Что | Источник |
|---|---|---|
| `+0` | журнал трансформации `RC_TransformLogStruct_LE` (с суммой) — на всех копиях столбца 0 (`[0][*]`), см. «Журнал трансформации» | [R:RC_ReadLogicalDeviceTransformLog, RC_Raid10NLogicalToPhysical], [B] |
| `+2` | журнал фоновой проверки массива, 0x2C байт: `+0x00` сумма по `+0x08…+0x2B`, `+0x08` ID тома, `+0x10` Handle, `+0x18` u64 `ArrayScanStart` (прогресс), `+0x24` u32 `ArrayScanCycleTime`, `+0x28` u32 1; остаток сектора — мусор. Пишется только на элемент 0 | [R:RC_ArrayScanLogIo], [A] (сумма сошлась) |
| `+0x80` | (используется при scrub RAID5/6) ? | [R:RC_ScrubRaid50NextRegion] |
| `+0x600` | (битовая карта ?) | [R:RC_Raid50LogicalToPhysical] |

## Раскладка данных [R:RC_Raid10NLogicalToPhysical, RC_Raid50LogicalToPhysical, RC_Raid60LogicalToPhysical]

Обозначения: `C` — секторов в блоке (`CacheTagSize`: 3 → 0x200, 2 → 0x100, иначе 0x80), `F` = FirstCount, `N` = SecondCount, элементы `[i][j]`, `i < F`, `j < N` (в записи LD подряд: `i×N + j`). Физический сектор = `UserDataSpace.SectorOffset` элемента + смещение. `ChunkSize` (`+0xAC`) в расчёте не участвует.

- **RAID10N** (`0x1BF6`): блок `k = LBA / C` лежит в столбце `i = k mod F`, смещение `(k / F)×C + LBA mod C`, на всех `N` зеркалах `j`. RAID0 — `N = 1`, RAID1 — `F = 1`. **= md raid0 / raid1 / raid10 `n<N>`** с порядком дисков `i×N + j` (проверено [X]: пары {0,1}, {2,3}; RAID0 2×1 — [A]).
- **Порядок участников — только по элементам LD**, не по портам и не по PCI: на [A] элемент 0 — диск на порту 1, элемент 1 — на порту 0.
- `ParentCount`-ссылка у тома: на [X] — серийный номер контроллера, на [A] — `0x40000000B105` (?).
- **RAID5** (`0x1BF5`, `F = 1`): полоса `s = LBA / (C×(N−1))`, номер блока данных `k`; P на диске `p = s mod N`; данные на `k`, если `k < p`, иначе `k+1`; смещение `s×C + LBA mod C`. **= md raid5 `ALGORITHM_RIGHT_ASYMMETRIC` (1)** (сверено с `raid5_compute_sector()` ядра).
- **RAID6** (`0x1BFA`, `F = 1`): полоса `s = LBA / (C×(N−2))`; P на `s mod N`, Q на `(s+1) mod N`, блок данных `k` на `(s+2+k) mod N`. **Размещение = md raid6 `ALGORITHM_RIGHT_SYMMETRIC` (3)**, но **Q несовместим**: у AMD — код **EVENODD** [R:RC_RAID6_EvenOddEncode, RC_RAID6_ComputeQ], у md — Рида–Соломона над GF(2⁸).
- RAID50/60 (`F > 1`): RAID0 из `F` наборов, единица чередования — полная полоса набора (`C×(N−1)` / `C×(N−2)`): набор = `(LBA mod (C×D×F)) / (C×D)`. В меню MSI таких уровней нет.

EVENODD у AMD [R:RC_RAID6_ComputeS, RC_RAID6_ComputeSingleQ]: простое `p = 17`; каждый сектор 512 Б делится на 16 строк по 32 Б; `a[r][j]` — строка `r` диска данных `j` (`j = 0…n−1`, `n ≤ 17`), строка 16 считается нулевой. `S = ⊕_{j=1..n−1} a[16−j][j]`, `Q[r] = S ⊕ (⊕_j a[(r−j) mod 17][j])` для `r = 0…15`. P — обычный XOR.

Следствие для md: RAID6 AMD можно **читать** штатным raid6 (в норме и при отказе одного диска данных — через P), но любая запись md испортит Q для AMD, а восстановление по Q невозможно. Нужен либо EVENODD в ядре (свой алгоритм в `raid6`), либо RAID6 только для чтения.

### `RC_ControllerDevice` (`0x25BE`, 0x88 байт) и `RC_SEPDevice` (`0x25BF`, 0x40 байт)

Описания контроллера (ID, имя, сборка BIOS, `MaxArraySize`, `SerialNumber`, VID/DID, `PCILocation`) и корзины (SEP: VendorID, ProductID, Revision, SerialNumber). Полные поля — `ondisk-structs.txt`. [B] UEFI переписывает их из своих таблиц без изменений. [D:28ae8]

## Пределы движка (UEFI) [D:init]

Слотов LD — 0x30 (48), дисков — 0x16 (22).

## Возможности платформы (меню «Create Array», IFR) [F]

`firmware/1A93/Raid.0.0.en-US.uefi.ifr.txt`, форма `0x210`:

- уровни: **Volume** (8), **RAIDABLE** (13), **RAID 0** (1), **RAID 1** (2), **RAID 5** (3), **RAID 6** (11), **RAID 10** (4) — в скобках значения в форме;
- CacheTagSize (размер блока на диск): **64 / 128 / 256 КБ**;
- кеш чтения: Read Cache / No Cache; кеш записи: Write Back / No Cache;
- размер массива (0 = максимум), единицы MB/GB/TB (десятичные);
- есть лимит числа массивов («maximum number of arrays have been created»);
- операции с дисками: Initialize (делает «RAID Capable»), Convert to Legacy, hot spare.

Это замена `--detail-platform` у Intel: ограничения для `super-amd.c` брать отсюда.

## Прошивка 1.A93 [F]

Модули (`firmware/1A93/guids.txt`):

| FFS | Размер | Что |
|---|---|---|
| `Raid` → **RAIDCoreDxe** (`RAIDCoreDxe.pdb`, движок `9.3.3-00277`, сборка 08/15/2025) | 338 КБ | главный UEFI-драйвер: сборка массивов, BlockIo для загрузчика, меню HII |
| `AmdRAIDCorePei` | 54 КБ | PEI, IA32, своё ядро RAIDCore `9.3.3-00202`; работает только в режимах загрузки восстановление/S3/capsule (см. ниже) |
| `NvmeRaidDxeMpio` | 13 КБ | переводит NVMe в режим RAID через SMU (см. ниже); с дисками и метаданными не работает |
| `UefiRaid` | 8 КБ | DXE: по `Setup` и PCD решает, включён ли RAID; ставит метку `0e29a4f4-…`; на каждый NVMe — вызов протокола `934ce8da-…` (см. ниже) |
| `AmdRaidPassword` | 10 КБ | DXE: пароли ATA (Security) SATA-дисков за RAID-AHCI; NVMe и метаданные не трогает |
| `AmdRaidRecovery` | 3 КБ | PEI, IA32: только в режиме восстановления публикует контроллеры AHCI/NVMe/RAID для `AmdRAIDCorePei` |

**`NvmeRaidDxeMpio` [D]** (REA/Ghidra 2026-11-01, выгрузка `firmware/1A93/ghidra/NvmeRaidDxeMpio/`, 16 функций):
- `entry` (`0x10bc`): флаги PCD (`0x19c`/`0x2ff`/`0x296` — включён ли NVMe RAID) → `0x1d0c`.
- `0x1d0c`: пишет переменную **`AMD_RAID`** (GUID `fe26a894-d199-47d4-8afa-070e3d54ba86`, атрибуты 7, 8 байт): бит 0 — NVMe RAID,
  бит 1 — PCD `0x5a3`, биты 2–3 (`0xC`) — PCD `0xf`. Отсюда наблюдаемое `AMD_RAID=0x0d`. При бите 3 ждёт
  `EFI_PCI_ENUMERATION_COMPLETE_PROTOCOL` и вызывает `0x1b90`; ставит свой протокол-метку `526e5ce9-9422-42b4-9419-671b6094b273`.
- `0x154c`: собирает список контроллеров NVMe: все `PciIo` с классом `01/08/02` (bus/dev/func), сверяя путь устройства
  (PNP `0A03`/`0A08`) с таблицами топологии `$A2B`/`$A07` протокола `3724cf01-00c2-9762-11b3-0ea8aa897200` (по-видимому,
  описание портов PCIe/MPIO AGESA); при PCD `0x65a` добавляет порты, где устройство не отвечает (ID `0xFFFFFFFF`). До 40 записей.
- `0x1b90`: передаёт список в протокол `2cec9c8e-bc8d-425b-98ca-778cde941fb7` (вызов `+8`, сообщение `0x20`; похоже на
  сервис SMU NBIO): сначала запрос лимита (`[0]=1` → лимит в битах 16–23 ответа), затем по одному `[0]=0, [1]=BDF`, затем
  `[0]=1`. Больше лимита — экран `AMD NVME RAID WARNING MESSAGE` / «Too many NVME devices under RAID» / «Please remove the
  extra devices…» (`0x11f8`).
- Вывод: модуль только просит прошивку SMU/MPIO перевести найденные NVMe в режим RAID (после этого они видны как
  `1022:b000` «RAID Bottom Device»). Чтения/записи дисков, метаданных RAIDCore нет. На стенде QEMU это состояние задано
  сразу (`nvme,amd-raid-id=on` → `1022:b000`), так что для `RAIDCoreDxe` стенд и ПК здесь равны.

**Остальные модули RAID [D]** (REA/Ghidra 2026-11-01; PEI-модули в формате TE переведены в PE `tools/te2pe.py`
с переносом базы на `0x10000`, адреса ниже — после переноса; выгрузки — `firmware/1A93/ghidra/<модуль>/`):
- **`AmdRAIDCorePei`** (151 функция): `entry` ищет PPI `b14748ce-fbcd-4d41-91e9-408690d47dac` (AMD; публикует
  `AmdRaidRecovery`), нет — ждёт его. Главная `0x10d55`: `GetBootMode`, продолжает **только при `0x20` (recovery),
  `0x11` (S3 resume), `0x12` (flash update/capsule)**, иначе `EFI_UNSUPPORTED`. Структура с подписью `RCPE`,
  `RAIDCore`, `0xE1E10000` (как версия пакета), строки `RCBNBGN`/`RCBNEND`/`9.3.3-00202`. Ставит виртуальный BlockIo
  восстановления (PPI EDK2 `695d8aa1…`, `26cc0fad…`), пользуется PPI AHCI/NVMe-контроллеров и pass-thru (GUID EDK2
  `61dd33ea…`, `cae3aa63…`, `6af31b2c…`, `a16473fd…`, `35de0b4e…` — сопоставлены по памяти, сверить с EDK2). Нижний
  уровень умеет и запись (`0x138dc`: ATA `0x25/0x35`, `0xC8/0xCA`, SCSI `0x28/0x2A`). **При обычной загрузке и в
  меню BIOS не работает** — к порче XPG отношения не имеет.
- **`AmdRaidRecovery`** (21 функция): при включённом RAID (PCD `0x19c`/`0x2ff`/`0x296`) и режиме `0x20` по
  событию публикует контроллеры классов `01/08/02`, `01/06/01`, `01/04` — для `AmdRAIDCorePei`.
- **`UefiRaid`** (10 функций, `entry` → `0x11ac` конструкторы библиотек `AmdCfgPcdBufLib`, `0x15d0`): читает `Setup`
  (GUID `ec87d643-eba4-4bb5-a1e5-3f3e36b20da9`, байты `+0x222`/`+0x22a`): RAID выключен → `EFI_UNSUPPORTED`; иначе при
  любом из PCD `0x19c`/`0x2ff`/`0x296`/`0xf` ставит протокол-метку `0e29a4f4-bfb2-4013-b39b-0beac733cf0c`; при PCD `0xf`
  ждёт каждый новый `PciIo` (функция `0x176c`, Ghidra её не создала — capstone): если класс `01/08/02` (NVMe) — берёт на
  этом же handle протокол **`934ce8da-5e2a-4184-8a15-8e0847988431`** и вызывает его `+8` с аргументом 0. Это
  **политика option ROM AMI** (полный образ 1.A93, `firmware/1A93/ami/`, выгрузка `ghidra/ami-PciBus/`): `PciBus`
  ставит протокол на каждое PCI-устройство рядом с `PciIo` (`0xc05c`), интерфейс `{Get 0x2844, Set 0x2884, устройство,
  байт политики +0x18, флаги +0x19}` с проверкой подписи устройства `$AMIPCI$` (`0x28b4`, начальное значение — из
  таблицы настроек по имени/ID устройства, `0x298c`); `Set` только пишет байт `+0x18`. Читает его загрузка option ROM
  (`0xb87c`): при значении 5 ROM не запускается (`StartImage` пропускается). **Тот же вызов `Set(0)` для каждого NVMe
  делает и штатный драйвер AMI `Nvme` (`0x5340`)** — общий приём AMI, к метаданным RAID отношения не имеет.
- **`AmdRaidPassword`** (12 функций): драйвер (`DriverBinding`) поверх ATA PassThru: по портам IDENTIFY, слово 128
  (ATA Security); каждому диску — протокол с подписью `$AMD`; при включённой защите — `SET FEATURES 0xEF/0x90`, код 6
  (выключить Software Settings Preservation). Только SATA, метаданные не трогает.

**Работа RAIDCoreDxe с NVMe [D]** (2026-11-02): драйвер сам ведёт контроллеры (тип `9` — AHCI, `0x16` — NVMe, массив
по `0x1368` байт) и ставит на них свои ATA/ExtSCSI/NVMe PassThru; `0x8254` — снятие контроллера из списка (снимает
протоколы, сдвигает массив; прямых вызовов нет). Включение NVMe — функция `0xc39c` (Ghidra не создала, есть только
указатель; capstone): `CC = 0x460000` → ждать `CSTS.RDY = 0`; `ASQ/ACQ/AQA`; `CC = 0x460001` → ждать `RDY = 1`.
Ожидание — `0xb8cc` (опрос `CSTS` раз в 1 мс), число попыток = `CAP.TO × 500` (`imul 0x1f4`), т. е. ровно `CAP.TO`
по спецификации; **регистр CRTO (NVMe 2.0) не читается**, `CC.CRIME` не ставится. Для XPG (`CAP.TO` 10 с, CRMS есть)
это 10 с. Опрос SATA (`0x1a3b4`, `0x1baa0`, `0x1a244`): COMRESET через `PxSCTL`, `PxSSTS = 0x103`, `PxSIG`.

Функции RAIDCoreDxe [D]:

| Имя | Адрес | Что делает |
|---|---|---|
| `RC_ConfigInit` | `0x20d68` | |
| `RC_ReadMetaData` | `0x29128` | читает `RC_MetaData` со всех дисков, DeviceID |
| `RC_ReadMBR` | `0x296cc` | читает LBA 0, сверяет `MBRChecksum` / тип `0x82` |
| `RC_ReadConfig` | `0x2a194` | читает `RC_ConfigCommit`, выбирает конфигурацию, читает пакет, разбирает (`0x2b908` → `0x28810`) |
| `RC_UpdateConfig` | `0x28e98` | сборка пакета (`0x28ae8`) → WriteAll → CommitAll |
| `RC_WriteAllConfigData` | `0x27fb4` | пишет пакет в кольцо на все диски |
| `RC_CommitAllConfigData` | `0x28388` | пишет `RC_ConfigCommit` на все диски |
| `RC_CommitDriveError` | `0x2b6e0` | |
| `RC_CheckConflict` / `RC_CheckAllConflict` | `0x2e8e0` / `0x2ec28` | |
| (меню) пакет + `RC_ConfigCommit` | `0x1d68c`, `0x1ded8` | второй, независимый писатель того же формата |
| (меню) LD из таблиц меню | `0x1d234` | |
| (меню) Initialize диска | `0x16e28` | зануление 20 МиБ, MBR, `RC_MetaData` |
| сумма | `0x698c` | |
| случайный 48-бит ID | `0x19aa4` | |

EFI-переменные: `AMD_RAID`, `NVME_TRAP_DEVICE`, `EnableHIPM`, `EnableDIPM`.

**Какие контроллеры берёт RAIDCoreDxe** (DriverBinding в `.data` `0x45780`, версия `0x1a`; `Supported` = `0xd00`, `Start` = `0xfc4`, `Stop` = `0x1cc4`; Ghidra их не декомпилировал, разобрано по дизассемблеру capstone) [D:d00]. Читает 0x40 байт конфигурации PCI через `PciIo`, затем:
- NVMe: при `AMD_RAID & 8` — только `1022:b000`, без этого бита — любой контроллер класса `01/08`. Берёт, только если `AMD_RAID & 4`.
- AHCI: таблица `0x33bf0` — `1022:7905`, `1022:7916`, `1022:7917`, `1022:43bd`, класс не проверяется. `1022:43bd` — только при `AMD_RAID & 1`; `7905/7916/7917` — только при `AMD_RAID & 2`.
- `AMD_RAID` читается из Linux (`/sys/firmware/efi/efivars/AMD_RAID-fe26a894-…`, 4 байта атрибутов `07` + u64; на ПК и в госте стенда — `0x0d`). mdadm с 03.11 (`amd_controller_ok`) повторяет эту проверку при создании контейнера и `--add`: диск на контроллере, который прошивка не берёт, — отказ (с `--force` — принять); сборка не ограничена; loop (без PCI) — можно.
- Т. е. `0x0d` у MSI = `43bd` + NVMe только `b000`. Проверок CPU и чипсета в `Supported` нет; в точке входа по CPUID (семейства `17h/19h/1Ah`) меняются только внутренние пределы, драйвер не отказывается.

**Какие регистры контроллера трогает RAIDCoreDxe (AHCI)** [D: capstone, `0x9d6c`–`0xa480`; порт — по декомпиляции, `ctx+0x90`]:
- Конфигурация PCI: заголовок `0x00–0x3F` (ID, Command — гасит IO-пространство, ABAR `0x24`, подсистема `0x2c/0x2e`). Только для `1022:7905` (смещения `0x82`, `0xc6`) и `1022:7916/7917` (`0x108`, `0x10a`) — запись u16: байт из глобальной структуры `<< 8` и константа `0x2a80`/`0x2a90`…`0x2a93` (по значению `+0x210` той же структуры: `0x4b/0x6b/0x1ff/0x26b`) — похоже на метку версии/рукопожатие с драйвером ОС. **Для `43bd` блок пропускается.**
- HBA: `PI = 0xff` (по AHCI — HwInit, только чтение; у AMD записывается), `GHC = 0x80000001` (AE + сброс HBA), ожидание снятия HR до 1000 × 1 мс, **пауза 1 с**, `GHC = 0x80000000`; `CAP & 0x1f`, `PI & 0xff` — не больше 8 портов, порт = ABAR + `0x100` + n·`0x80`.
- Порт: только стандартные `0x00` CLB, `0x0c`, `0x10` IS, `0x18` CMD, `0x20` TFD, `0x24` SIG (`0xEB14…` → IDENTIFY PACKET), `0x28` SSTS, `0x2c` SCTL, `0x30` SERR, `0x38` CI; вендорская область `0x70–0x7F` не используется.
- NVMe — свой драйвер по стандарту (очереди, doorbell с `0x1000`).
- Вывод: на пути `43bd` нестандартного нет, кроме записи в PI (на чужом чипе, вероятно, игнорируется).
- **Пути ошибок** [D, агент 03.11]: ожидание команды `0x1a6b4` (`GHC=AE`, `CI=1`, опрос раз в 200 мкс; R/W — 8 с). Ошибка (`TFES`+`TFD.ERR` или `IFS`) → снять `ST`, `FRE`, сброс `SERR`, при `TFD&0x88` — COMRESET, перезапуск, код 4. Тайм-аут → `0x1a574`: при `SERR&0x3fe0f03` COMRESET, сброс `SERR`, `SUD`, ждать BSY ≤1 с, код 0xe (команду не снимает). COMRESET `0x1a3b4`: `SCTL=(SCTL&0xF0)|0x301` 2,75 мс → `|0x300` 25 мс → ждать `SSTS=0x103` → `0x1a350` (`SCTL=0x300`, CLB/FB, FRE/ST, `SERR=0x7ff0f03`). `SUD` — по биту CAP `0x200` (внутри NCS; гипотеза: ошибка вместо SSS). `GHC.HR` — только при старте. Повтор один (`0x15c10`, 2 попытки). NVMe: 5 с на команду (`0xb738`), без Abort, сброса и `CSTS.CFS`. **Ввод-вывод метаданных (`0x25810`) код ошибки игнорирует** (ошибка записи конфигурации прошивке не видна). `0x10` у элемента — только при записи в элемент с `0x20` (`0x2f7a8` → `0x2b604`, разрешение `0x27c4c`, иначе `0x4000`) → `RC_CommitDriveError` `0x2b6e0` → `RC_UpdateConfig` → `0x8000`; `0x20` ставят `0x2c6c4` (диск не найден) и `0x2b320` (устаревший). Вендорских регистров (порт `0x70–0x7F`, HBA `0xA0+`, PCI `0xF8/0xFC`) нет.
- **Индикаторы** [D]: AHCI — нет. NVMe — только Dell FlexBay по I2C (переменные `DellPlatformFlexBayParameters` GUID `ded959ad-1d14-4a43-849d-9cc38cc91353`, `DELL_LED_FLIP_I2cADDR`; привязка по BDF `0x1949`, команда `0x83a0`: I2C Master `cd72881f-…`/`dc27881f-…` или свой DesignWare `0x8534` на FCH `0xFEDC2000…`; запись `[рег, код 0–3, 1]`); команды `RC_LED_ON/OFF` (`0x4005/0x4006`), `RC_LED_XTEND_1..4`. На MSI переменной, видимо, нет (гипотеза). Драйвер ОС [R:ahciSgpioInit @00124690, ahciAmdSgpioSend @00124250]: SGPIO AMD через конфигурацию PCI (`0xF8` занятость, `0xFC` = биты|порт<<8|`0xB0/0xB1`), SB900 и Intel — AHCI EM; NVMe — I2C (`nvmLEDControl` @00126b90, коды `0x100` нет, `0x101` отказ, `0x102` поиск/пересборка). `rcadm --blink` (`RC_CMD_MANAGE_PHYSICAL_DEVICE` 0x1d) перезаписывает метку `RC_MetaData` каждого RAIDCORE_DISK (`RC_UpdateMetaData` @001357f0, полный u32 `Features`), пакет не пишет [R]; `-rsc` → `RC_ConfigRescan` @0015c8e0 (с `RC_UpdateConfig`, гипотеза: пишет при смене PD); `-ptr` — вероятно `RC_EJECT_DEVICE` (0x4021), тот же путь.
- **`Features` у драйвера ОС** [R:RC_HW_BTM_GetPhysDriveInfo @0010d3e0, RC_UpdateDeviceFeature @00168280, RC_HW_SATA_IdentifyComplete @00118150], [W:FUN_1400033cc]: старшие 16 бит — `SataParams.Flags` (`0x1` LBA48, `0x4|0x8` NCQ, `0x10` NCQ запрещён, `0x20/0x40` кэш записи есть/вкл (IDENTIFY w82/w85 b5), `0x80/0x100` упреждающее чтение есть/вкл (b6), `0x2000` w76 b2); младшие — настройки из метки: `0x1` кэш записи вкл, `0x8` по умолчанию, `0x2` упреждающее чтение вкл, `0x10` по умолчанию, `0x4` SMART; без метки `0x18`. `0x6d001c` (Windows на QEMU) = LBA48+NCQ+кэш + `0x1c`; X399 `0x21ED001C` — плюс упреждающее чтение и Gen2 (это же u32 в метке [X]); NVMe `0x220f` — константа (у [A] так же; смысл — гипотеза). Прошивка пишет свою кодировку в младшие биты (`0x2900`) [D:1bbf4].
- **Номер порта (`Handle.Internal`) у драйвера ОС** — не физический порт, а `RC_HW_CmnDriveInfo.Index` (`+0xD7`): первая свободная из 24 ячеек от 0 по порядку обнаружения [R:RC_Proto_AddDrive], [W:FUN_1400033cc]; у [A] и Windows на QEMU — с 0. У RAIDCoreDxe — индекс его таблицы +1, Handle 0 для ввода-вывода недопустим [D:15c10, 25810]. Прошивка сопоставляет диск с PD и элементами **только по DeviceID метки**: при расхождении Handle ставит PD флаг `0x80` (+0x54) [D:29128], Handle элемента в памяти заменяет текущим, ненайденному — `0x20` и offline-handle `0x8000−n` [D:2c6c4]; Legacy-LD принимает PD `0x1202/0x1203`. **Для mdadm:** конфигурацию от Windows сохранять как есть (Handle/Features PD не трогать), сопоставлять только по DeviceID, Handle 0 не считать отсутствием; при создании — 1-based, как прошивка.

**Драйвер Windows (rcraid.sys 9.3.3.218) как второй судья** [W-ВМ, 03.11: Windows 10 IoT LTSC на нашей QEMU с ID AMD, `tools/qemu/win11.sh`]:
- Установка по руководству AMD 56268 гл. 5: `rcbottom` (одна установка; садится на `1022:43bd` и `b000`) → `rcraid` (на шину rcbottom) → `rccfg` (AMD-RAID Config Device). Первая установка `rcraid` подвесила ядро (все vCPU на фиксированных RIP, обращений к AHCI/NVMe нет) — после перезагрузки повтор прошёл.
- Тома, созданные mdadm (RAID1 4 ГиБ, RAID0 8 ГиБ), — «AMD-RAID Array 1/2», Online/Healthy. Windows разметила GPT+NTFS и записала файлы — **Linux (наш mdadm) прочитал все 6 файлов бит в бит**.
- **Драйвер переписал конфигурацию** (12 → 19): PD перенумерованы **с 0** (порты 0–4; прошивка и mdadm пишут 1–5), `PD.Features 0x6d001c` (у прошивки `0x2300`), пустые NVMe — PD `NOT_INITIALIZE` (`f=0x220f0018`) + LD `LEGACY` на каждый, без метки RCRAID на самих NVMe. Тома и их ID не тронуты. **Прошивка такую конфигурацию принимает** [Q, снимок `30-win-rewritten`, 03.11]: тома Unit 1/2 видны с разделами GPT от Windows, при загрузке конфигурацию не переписала (номер 23, порты с 0) — нумерация портов PD (0 или 1) для RAIDCoreDxe значения не имеет.
- Кеш драйвера [D: rcraid.sys `FUN_14006ee68` RCInitDataMemory, `FUN_140039afc`]: память берётся один раз при загрузке — core data 20 МиБ (`0x1400000`, при нехватке −1 МиБ шагами) + data 8 МиБ (`0x800000`, пул `RCRD`); кеш — буферы по `0x40d0` Б (16 КиБ + заголовок) и описатели `0x170`, не меньше 256 (128). Не зависит от числа томов и политики `Cache` LD — политика меняет поведение (write-back), а не объём памяти.

**Миграции (трансформации `rcadm -T`)** [Q-rcraid 9.3.3-00302, 07.11; `dumps/2026-11-07-rcraid-migrations/`]:
- **RAIDABLE → RAID1** (новый диск): пока идёт — две LD с одним ID: исходная (тип `0x1BFB`, `TransformType`/`LastOperation` `0x5354`
  NORMAL, `TransformLink=1`, `Flags=0x20010`, gen N) и за ней целевая (`0x1BF6` 1×2, gen N+1, `attr 0x1`, `TransformLink=0`, `Flags=0`);
  элемент нового диска — **с тем же смещением**, что исходный (`0x100000`/`0x105000`, пустой диск). Журнал трансформации — на обоих
  элементах столбца 0 (`AllocatedSpace + 0`): тот же формат, что у пересборки, `type 0x5354`, `done` (секторы), `flag 1`, ID тома.
  После — одна LD `0x1BF6` NORMAL, `last=NORMAL`, `state 0xa1a6`, журнал обнулён. ID и размер тома — прежние.
- **Расширение RAID1 2 → 4 ГБ на тех же дисках:** место за элементом занято (на SATA0 — элемент RAID5) → том **переносится в новый
  экстент** (`alloc 0x70a000`, 3,81 ГиБ = запрошенные 4096 МБ, округление): исходная LD (`0x5354`, link 1, `Flags 0x20010`) + целевая с
  новыми элементами и `capacity`; журнал — в начале **новых** элементов (`0x70a000`, `type 0x5354`, `done 92160`). После — одна LD.
  Known issue AMD 00302: «Online Capacity Expansion of a RAID10 and Volume array fails».
- mdadm (с 07.11): RAIDABLE → RAID1 посреди миграции собирает как md raid1 из двух, новый диск догоняется с отметки журнала, mdmon доводит (пакет «100 %» → журнал обнулён → одна LD, как AMD); `mdadm --grow <RAIDABLE> -n 2` начинает её так же, как AMD (журнал, затем пакет с двумя LD; судья rcraid — `notes/agent-grow-judge.md`). Другие миграции (расширение и пр.) не собирает («a migration is in progress»).
- Секции 25BE/25BF заголовка пакета: BIOS при пустых пишет 0/0 (дампы HDD MSI); драйверы AMD держат пустую 25BF сразу за 25BE (дамп ASRock: 25BE `0x8e0`/`0x220`, 25BF `0xb00`/0; rcraid 00302 в m1: `0xfc8 = 0xf40 + 0x88`) — mdmon сдвигает их вместе с данными (`amd_move_sections`).

**Уровень возможностей контроллера и «лицензия»** [агент 03.11; D, W, R]:
- Уровень (`ControllerFeature`) задан **константой платформы**: RAIDCoreDxe — поле `+0x210`, в конце инициализации безусловно `0x6b` (`0x900`/`0x705`), переменные UEFI/PCD/Setup на него не влияют [D]; rcbottom.sys отвечает rcraid.sys константой `0x2a110000` (`0x14000a62f`) → `0x6b` [W:FUN_1400091fc, FUN_14007477c]; rcblob — `RC_HW_OS_GetLicenseLevel` @00101280 по CPUID `0x2a110000`/`0x2a140000` [R]. Перевод `(L>>16)&0x7f`: 1/0x10/0x1d → `0x4b`, 2/0x11 → `0x6b`, 3/0x12 → `0x1ff`, 4/0x13 → `0x26b`, 0x15 → `0x204b`, иначе `0x400` [R:RC_Proto_DiscoverAdapter]. Уровень пишется в `ControllerFeature` и в «серийный номер» контроллера ([A] `0x40006b008590`, `0x6b`; [X] `0x40004b…`, `0x4b`). Для `7905/7916/7917` прошивка передаёт его драйверу ОС через PCI `0x82/0xC6`, `0x108/0x10A` (`0x2a90…0x2a93` для `0x4b/0x6b/0x1ff/0x26b`, `0x9d6c`).
- **Серийный номер контроллера** (`ModifierSerialNumber` пакета, `LastOnlineSerialNumber` блока фиксации, PD `RAIDCORE_CORE`, ссылка LD на родителя) [08.11, `notes/agent-serial.md`]: прошивка MSI 1A93 — константа `0x859010220000` (`movabs` @0x16e8 RAIDCoreDxe); rcraid.sys 9.3.3.218 — `uniqueId` виртуального контроллера VSTOR `8590:1022` (`vendor<<32 | device<<16`, @14000fe6c); **блоб Linux** (`RC_STH_DiscoverAdapter`, все известные сборки 9.3.2–9.3.3-00302) — константа `0x102285900000` (половины перепутаны; на ПК 08.11 [HW] и на стенде). X399 и ASRock — тоже `859010220000`. AMD при любой записи ставит свой серийный (набор из чужих дисков становится своим; при смешанном наборе чужие элементы того же LD не связываются — vm-test 12в). `super-amd.c` с 08.11 делает так же (`amd_take_over`, vm-test 12в2), UUID — от `AMD_SERIAL`.
- Биты [R:RC_CreateRaidArray @00146860, RC_CreateTransformRaidArray @00148300, RC_ValidateLogicalDevice @001311d0]: `0x1` расширение на лету, `0x2` смена уровня, `0x8` массив на нескольких контроллерах, `0x10` распределённый резерв, `0x20` RAID5, `0x40` кеш тома, `0x80` RAID50 / RAID1 >2 дисков, `0x200` RAID6, `0x2000` без RAID10, `0x4000` без VOLUME, `0x8000` без RAIDABLE. `0x4b` — без RAID5 (X399), `0x6b` — с RAID5 (MSI, ASRock), `0x26b` — с RAID6. Пределов числа дисков/массивов в уровне нет (16 элементов — в коде).
- **Меню показывает RAID6 только при `+0x210 & 0x200`** (`FUN_0000ed9c`, `0xf0e1`) — на MSI скрыт; движок EVENODD и код `0xb → 0x1BFA` есть [D].
- Ключ лицензии — 16 Б `RC_FullFeatureKey` в `RC_ControllerDevice.ControllerInfo` (`0x25BE` +0x14), у [A] и [X] нулевой (rcadm выводит `11111-…`, гипотеза); `RC_ValidateKey` @0010b2a0 — проверка чётности 11×11 + серийный номер; ключ влияет только на `RC_GetFeatures` @001946f0 (проверка существующих томов, резервы, трансформации), **создание массивов проверяет `RC_CoreFeatureSet` без ключа** [R]. Драйвер ОС **выключает существующий RAID6** («offline due to RAID6»), если в `RC_GetFeatures` нет `0x200`. Обход ключом — снятие лицензионного ограничения AMD, вне рамки проекта (не делаем). **Для mdadm:** RAID6 AMD не создавать (Windows его не примет, меню MSI не создаст); существующий — собирать md только на чтение (Q = EVENODD).

**RAIDCore на других платформах** [агент 03.11; **[H:плата]** — RAIDCoreDxe из BIOS HEDT, **[S:адрес]** — Dell `bcraid690.sys` 6.9.0-0001; модули — `firmware/<плата>-<версия>/`, Dell — `references/dell-s150-6.9.0.0001/`]:
- Версии RAIDCoreDxe: X399 ASUS Zenith Extreme 2601 — 9.2.0-00087 (2018); TRX40 ASUS Zenith II Extreme 2601 = MSI Creator TRX40 7C59v17 — 9.3.0-00140 (один файл); WRX80 ASUS WRX80E-SAGE 1901 — 9.3.0-00308; TRX50/WRX90 ASUS SAGE 1405 — 9.3.3-00117 (две копии, GUID F29729C7 и AFD69E65); MSI X870E 1.A93 — 9.3.3-00277 [H], [D].
- **Формат на диске один и тот же с 9.2.0**: RAIDCore/0x30000, 0x5000/0x5001/0x5800/0x6000, 0xE1E10000 (в 9.2/9.3.0 — константа в данных, X399 0xf468), PD 0x80, 25BE 0x88 [H; сверено с дампом [X], та же плата X399: 25BE 544 Б].
- Уровень возможностей: 9.2.0 — всегда `0x4b` (X399 0x1be3f; [X] — 0x4b); 9.3.0 — `0x4b`, а `0x6b` только при CPUID 0x80000001 EBX[31:28] = 4/7 и CPU ≠ 0x800F10/0x800F80 (TRX40 0x1e805, WRX80 0x2057d); 9.3.3 — ветки по CPUID есть, но в конце безусловно `0x6b` (TRX50 0xa3b, поле +0x408; 1.A93 0x900, +0x210) [H], [D]. **RAID6 (бит 0x200) не ставит ни одна прошивка**; пункт RAID 6 есть во всех IFR, скрыт проверкой бита 9 (TRX40 0x3c336) [H].
- Таблица AHCI в `Supported` у всех версий одна: 7905/7916/7917/43bd; NVMe `b000` — с 9.3.0, в 9.2.0 NVMe по классу 01/08/02 [H]. Меню: 9.2/9.3.0 — 16 слотов дисков, 9.3.3 — 32 и обновление прошивки дисков; полоса 64/128/256 КБ везде [H]. PEI RAIDCore и `AmdRaidPassword` на HEDT нет; в TRX40/WRX80 — `AmiAmdUefiRaid` (164E5590) вместо `UefiRaid`.
- **Dell PERC S150** [S]: отдельная ветка RAIDCore 6.x (DHS_v6.0, © Ciprico/Dot Hill). Садится сам на 1022:7916 (подсистемы Dell 08FC–0900, 0A2D), Intel A206/A256/A1D6/A186/43D6, NVMe по списку моделей (31 ID; `bcraid6.inf`, `swraidNvmeDeviceId.txt`); rcbottom/b000/43bd нет.
  - 512/512e — формат как у AMD 9.3.3: RC_MetaData (`RC_UpdateMetaData` ≈0x140009cc0: RAIDCore, 0x30000, 0x5001, 0x5800, 0x800), commit (+0x18, +0x28 — `RC_ReadConfig` 0x14000f890), пакет 0xE1E10000 v1, та же сумма (0x14007bb20), проверки LD те же.
  - 4Kn: структуры по 0x1000, LBA 0xA00/0xA01/0xB00, кольцо 0x100 секторов 4К, сумма метки +0x08…+0xFFF. У AMD 4Kn нет [W, R].
  - `RC_ControllerDevice` 0x80 Б (без OrigVendorID/OrigDeviceID/PCILocation), ControllerDeviceSize = N × 0x80; AMD разбирает шагом 0x88 [R: RC_ConfigRescan] — вторая и следующие записи чужого формата не читаются.
  - Разбор LD принимает только 0x1BF5/0x1BF6/0x1BF7/0x1BF9, иначе останавливается (`RC_BuildConfigMetadataFromRing`); кода RAID6 (0x1BFA) нет.
  - Уровень: NVMe `0x6d`, AHCI — из серийного номера контроллера (`0x4000|уровень`, иначе «BC-UNLICENSED»), `RC_MinFeatures` = 0x6d AND … (0x14007c800, 0x1400b09a0); RAID5 — бит 0x20, RAID6 недоступен.
  - **Для mdadm:** массивы S150 на 512/512e читаются (серийный номер — из пакета, 25BE переносится как есть); 4Kn — не поддержано; RAIDABLE (0x1BFB) S150 не прочитает. Чужим ли S150 и AMD считают серийный номер друг друга — не выяснено. Нужен дамп S150 (решение владельца).

**RAID5/RAID10 на данных, Windows-судья** [агент 03.11, W-ВМ; `tools/boot/win-raid-check.sh`, `tools/qemu/win/ntfs-raid.ps1`, `verify-raid.ps1`]:
- Windows → Linux: `rcadm -C` RAID10 4 диска (64K, 256K), RAID5 4×64K и 3×128K; GPT+NTFS, 12 файлов — наш mdadm прочитал 12/12, `md check` mismatch 0 на всех (отрицательный контроль: 4 КиБ мусора → mismatch 8 у RAID5, 128 у RAID10). **RAID5 AMD = md raid5 right-asymmetric** (проверено на данных, оба размера блока).
- Linux → Windows: файлы через ntfs3 rw на все 4 тома + RAID5 из нашего `-C -l5` (3×256K, init resync'ом md) — Windows: все файлы и сырые данные совпали, тома NORMAL, `rcadm -M -cs` «completed». Деградация: Linux без диска пишет → CRITICAL, элементы `0x30`; Windows читает всё (восстановление из чётности md); после пересборки mdmon — NORMAL, check чистый.
- **Журнал трансформации RAID5 у AMD** лежит только на двух элементах — данных и чётности для «полосы за концом» (`RC_Raid50LogicalToPhysical`, флаг 0x10000); поля `IOStart=ProtectStart`, `IOSize` = блок, `TFlags` — флаги LD (0x241 у тома `rcadm -C`; на томе меню / нашего `-C` rcraid.sys пишет **0x211** [W-ВМ 07.11, `notes/agent-winjudge2.md`]), `DynProtStripe = LogUpdStripe = ProtectSize/полоса` (0x90, 0x48). Нули в этих полях драйвер принимает у зеркал только для пересборки и миграции (размер I/O пересчитывается на каждый регион), но не у инициализации (см. «Журнал трансформации», инициализация) и не у RAID5 (иначе «task has failed», том OFFLINE). Отметка: `0x44a900` = 1 499 904 × 3 (md считает resync RAID5 в секторах участника).
- `rcadm -M -cs` молча чинит копию RAID10 (по `[i][0]`), испорченную чётность RAID5 не исправляет и не сообщает — судьёй для чётности RAID5 не годится.
- Отработав без диска, Windows обнуляет ID элемента (offline handle) и убирает PD отсутствующего диска — вернувшийся диск mdmon не опознаёт (нужен резерв или `--add`).
- Возможная ошибка у нас (зеркала): mdmon пересобрал r1 на вернувшийся диск, но PD этого диска в пакет не вернул — проверить.

**Возврат диска, Volume и эталон `rcadm -C`, Windows-судья** [агент 04.11, W-ВМ; дампы `-v` на ПК `~/src/qemu-amd/win/j2/dumps/`]:
- **Драйвер Windows, отработав без диска:** PD диска убирает из пакета, у его элементов — offline handle (`0x8fff`…), флаги `0x30`, LD CRITICAL. При возврате диска: PD возвращается (порт по порядку обнаружения), **ID его элементов обнуляется** (handle `0x9000`, `0x30`); если диск — глобальный резерв (0x100 в метке и PD), Windows сама пересобирает на него (первый свободный экстент), если нет — тома остаются CRITICAL (нужно действие пользователя). Пакет без PD у пересобранного элемента Windows чинит сама. `tools/amdraid_winsim.py` (`drop`/`forget`) воспроизводит это на образах.
- **mdmon (с 04.11):** пересборка на диск без PD — вставляет PD (первый свободный порт, SpareInfo из метки) и ставит элементу его порт; возврат диска при работе (udev `-I`): ATTACH принимает диск без PD, если его ID есть в элементах; `raid_disks`/`container_id` учитывают участников с убранным PD; у членов контейнера `raid_disk = -1` (как IMSM — иначе `-A` терял один из дисков с одинаковым слотом после сдвига PD). ID элемента на месте — пересборка в слот; обнулён — только через `--add` (диск становится глобальным резервом, пересборка на него), как у AMD. `--add` пустого NVMe, записанного Windows как PD NOT_INITIALIZE + Legacy LD — отказ («инициализируйте в меню BIOS или `rcadm -M -id`»; `rcadm -M -id`: тип PD → RAIDCORE_DISK, порт сохраняется, Legacy LD удаляется).
- **Volume ↔ Windows:** наш `-C -l linear` (2 диска разного размера) — Windows читает сырые данные через границу участников и NTFS, Linux читает NTFS Windows; Volume из `rcadm -C` — md linear читает.
- **`rcadm -C` против нашего `-C`** (одна база, снимок 29): совпадают смещения и размеры экстентов, порядок элементов и зеркал (RAID0/1/10/5/Volume), cache 0xc0000000, CacheTagSize, attr; RAID5 — целиком. Отличия не по раскладке: у RAID0/Volume rcadm пишет LastOperation 0 (меню и мы — CREATE_REDUNDANCY), флаг элементов 0x40000 (меню его не ставит); флаг LD 0x2 — на всех LD, которые пишет Windows. `rcadm -s` — в MB (10^6 Б), участник округляется вверх до МиБ; RAID1 из rcadm сразу NORMAL/COMPLETED (без инициализации), RAID10/RAID5 — CREATE. **Инициализацию драйвер пишет и в LD пакета** (TransformState STARTED 0xa1a1, ProtectStart, Flags 0x226) — гипотеза «ход только в журнале» неверна; mdmon так не пишет, Windows наше принимает. Лимит rcadm — 12 массивов (Legacy LD в счёт).

**Что показала эмуляция** [Q] (`dumps/2026-10-31-qemu-raidcore-msi1a93/`):
- Совсем пустой диск (нули в LBA 0) — состояние «Unknown», статус «New»; Initialize его не предлагает, Create Array недоступен. С любым MBR (раздел `0x83`) — «Legacy», Initialize доступен. По коду: состояние PD для меню берётся из внутреннего поля (`FUN_0000dc88`): `2` → Legacy (считается в «можно инициализировать», байт `0x2C8` varstore `MyRCPhysDisks`), `4` → RAID, `0`/`8` → прочее [D].
- Меню MSI 1.A93 предлагает уровни Volume, RAIDABLE, RAID0, RAID1, RAID5, RAID10 — **RAID6 нет**; имени тома не спрашивает (`DevicePrivate` пустой). CacheTagSize 64/128/256 КБ → `CacheTagSize` 1/2/3, `ChunkSize` = 0 — подтверждено.
- RAID5 на 4 дисках: `0x1BF5`, First=1 Second=4, ёмкость = 3 × размер элемента; RAID10 на 4: `0x1BF6` 2×2; RAID1 на 2 NVMe: `0x1BF6` 1×2. У новых томов `transform=CREATE_REDUNDANCY` и две копии LD (`TransformLink` 1/0); после следующей записи конфигурации у тома `State=NORMAL`, `Flags=0x100`.
- Второй том на тех же дисках ложится сразу за первым: `AllocatedSpace` второго начинается с конца `AllocatedSpace` первого (`0x100000 + 0x778000 = 0x878000`), данные — через 0x5000.
- **Устаревший диск при загрузке** [Q] (снимок `07`): если один диск конфигурации отстал (не получил последние пакеты), RAIDCoreDxe сам пишет новую конфигурацию (`+0x38=0` в блоке фиксации — значит, это поле не признак «записано AMD»): в копии LD тома, где диск участвует, элемент обнуляется с флагом `0x20`, том CRITICAL; записи PD при этом вышли с испорченными DeviceID (ASCII «9.3.»), секции 25BE/25BF получили смещение конца LD и размер 0. Вывод для mdmon: конфигурацию, без которой можно обойтись, писать только когда все диски на месте.
- После Initialize: MBR `0x82` с `0x3F`, `RC_MetaData`, блок фиксации и пакет конфигурации, в котором PD «ядра» (`859010220000`) и все инициализированные диски; суммы сходятся с нашим `amdraid_dump.py`.

## Платформа exeroom-pc [P]

- SATA в режиме RAID: `1022:43bd` класс RAID, их держит `ahci` («RAID mode») — диски видны напрямую.
- NVMe в режиме RAID: `1022:b000` «RAID Bottom Device» (subsystem `1cc1:646a` у XPG), класс `0108` — держит штатный `nvme`.
- `AMD_RAID` (`fe26a894-d199-47d4-8afa-070e3d54ba86`): `0x00` — выкл, `0x1–0x3` — SATA RAID, `0xc` — NVMe RAID, `0xd–0xf` — оба. MSI при SATA RAID ставит `0x0d`.
- md на ПК: XOR — `avx`, RAID6 — `avx512x4`, восстановление — `avx512x2` (dmesg после `modprobe raid456`).

## Реальная плата: MSI X870E, BIOS 1.A93, массивы из меню (2026-11-01) [M]

Источник **[M]** — `dumps/2026-11-01-msi-x870e-hdd/` (4 HDD SATA + XPG NVMe Legacy, конфигурация 19).

- **RAID0** из меню: `0x1BF6` First=2 Second=1, **одна копия LD** (без `TransformLink`), `TransformType 0`, `LastOperation CREATE_REDUNDANCY`, `TransformState 0`, `State 0x200`, **`Attribute 0`** (битовой карты нет), `Cache 0xC0000000`. [M]
- **Volume** из меню: `0x1BF7` (`RC_VOLUME`), First=1 Second=1 (один участник), одна копия, `State 0`, `Attribute 0`. [M]
- RAID1/RAID10/RAID5 — как на стенде: две копии LD, `CREATE_REDUNDANCY` не начат, `Flags 0x100` у основной. [M]
- `PD.Features` у SATA-дисков **`0x2900`** (на стенде QEMU — `0x2300`), у NVMe `0x2100`; метка — `0x1C`. [M] **Расшифровано по RAIDCoreDxe** (2026-11-03; SATA — `FUN_0001bbf4`, разбор ATA IDENTIFY и порта AHCI; NVMe — `FUN_0000c950`, `|= 0x2100`): `0x100` — SMART поддерживается (IDENTIFY слово 82, бит 0), `0x2000` — SMART включён (слово 85, бит 0), **скорость линка** по `PxSSTS.SPD` (порт +0x28, биты 7:4): `0x200` Gen1 1,5 Гбит/с, `0x400` Gen2 3, `0x800` Gen3 6; `0x4000` — при бите `0x20` в возможностях контроллера и бите 21 `PxCMD` (внешний порт). Значит `0x2900` = SMART + 6 Гбит/с (HDD MSI), `0x2300` = SMART + 1,5 Гбит/с (AHCI QEMU); гипотеза «`0x800` = HDD» неверна. `super-amd.c` (`amd_pd_features`): так же — IDENTIFY через SG_IO, скорость из `/sys/class/ata_link/linkN/sata_spd`; если спросить нельзя (loop) — `0x2300`.
- Порты (Handle): XPG (Legacy, NVMe) — 1, HDD — 2…5. [M]
- **Legacy-диск в конфигурации:** PD `DeviceType 0x1203`, ID `7d730af340a81267`; LD `LEGACY_DEVICE` (`0x1BF9`) — у нас **две**, обе `State 0x202` OFFLINE, элемент `DeviceID 0xFFFFFFFFFFFFFFFF`, `Handle 0`, `UserDataSpace 0 + 0xEE775000`. С такой записью прошивка не связывает XPG с массивом и не отдаёт его для загрузки (`M2_2 Not Present`). Владелец XPG не удалял. **Причина (опыт на ПК 02.11, `dumps/2026-11-02-msi-x870e-hdd/`):** при создании в меню массива на все 4 HDD (RAID10, RAID5) Legacy-LD XPG становится OFFLINE с элементом `0xFF…FF`; после первого раза драйвер заводит новую Legacy-LD (новый ID), после второго — и она OFFLINE; PD XPG остаётся Legacy без массивов. На 2-дисковых массивах и на стенде QEMU (та же раскладка и ID) — нет. [M] Сломанная Legacy-LD отличается от здоровой ровно тремя полями: `State` `0x202`/`0x200`, элемент `DeviceID` `0xFF…FF`/ID PD, элемент `Handle` 0/порт PD (`routing` 1 остаётся). Восстановление этих полей и удаление лишних Legacy-LD (`tools/amdraid_fix_legacy.py`) возвращает загрузку с XPG — проверено на стенде и на ПК (02.11). [M] У ASRock [A] (записано драйвером Windows) элемент Legacy-LD — нормальный ID диска. [M]
- Пустой диск (нули в LBA 0) — «New», Initialize его не предлагает; **Delete Array** на его Non-RAID-«массиве» делает его «Ready» (инициализированным). [M]
- Служебную область тома (`AllocatedSpace … +0x5000`) меню **не обнуляет** — там остаются старые данные; на элементах `[0][0]` меню пишет 17 байт (журнал фоновой проверки, `+2`?). [M]
- В меню нет RAID6 для 4 SATA-дисков; RAIDABLE пропал после создания остальных томов. [M]
- **Windows-драйвер `rcraid.sys`** (9.3.3.218, разбор агента 06.11 — `notes/rcraid-sys.md`): ядро RAIDCore — тот же исходник, что `rcblob` 9.3.3; конфигурацию пишет по кольцу следом за живым пакетом (номер +1 от максимума, prev = прежний LBA диска) и при каждом старте драйвера; резерв: выделенный → распределённый → глобальный; Legacy не чинит; флаги элемента на диск: RAID1/5/10 `& 0xFFF`, RAID0/Volume — без `0x10`; ёмкость PD — `round_down(N−0x100000, 0x40000)+0x100000`; порченая сумма MBR → диск Legacy. [W-код]
- **RAID1 только из 2 дисков:** меню при 3 дисках — «An invalid number of disks were selected for the chosen RAID level» [M 06.11]; ядро — бит платформы `0x80` [R].
- **Условия меню и запись конфигурации меню** — подробно `notes/fw-menu-conditions.md` (агент, 06.11, по дизассемблеру RAIDCoreDxe):
  - «Create Array» серый — **12 массивов на контроллер вместе с Legacy-LD** (копии LD x2 неинициализированных томов не считаются) [R:FUN_0000f140; M 06.11: 12 → серый, удалили один → активен]. Ядро лимит не проверяет: Legacy-LD заводит в любом из 48 слотов («Array 13» 05.11).
  - «Manage Dedicated Hot Spares» — только RAID1/5/10/50; кандидат — диск без SMART-ошибки, ёмкостью не меньше наименьшего участника и **без единого элемента в каком-либо LD** (целый свободный диск); не более 4 [R:FUN_00013200, FUN_00006e24]. На ПК 06.11 — серый (все HDD заняты) [M].
  - RAIDABLE в списке — если есть диск Ready без элементов в LD [R:FUN_0000ed9c]. Volume — от 1 диска, RAID0/1 — от 2, RAID5 — от 3, RAID10 — от 4, RAID6 — бит платформы 0x200.
  - **Меню пишет конфигурацию не в кольцо по порядку:** позиция диска в таблице меню обнуляется при каждом пересканировании (после каждой операции), LBA = позиция + размер пакета → первая запись операции в `0x5800`, вторая — в `0x5815`; `PreviousConfigPacketOffset` = 0; номер конфигурации — счётчик записей меню с загрузки драйвера (с диска не читается: 56 → 3) [R:FUN_0001ded8; M дампы 05.11, 06.11]. Delete пишет дважды. mdadm выбирает пакет по наибольшему номеру commit-сектора и его смещению — сброс номера не мешает (все диски сессии получают одинаковый); риск — диск, пропустивший сессию меню, со старым большим номером.
  - **Порча Legacy (механизм, частично гипотеза):** при пересканировании после операции, если Identify какого-то SATA-диска не успел, скан повторяется без очистки таблицы PD меню, XPG сталкивается со своей записью и получает случайный DeviceID [R:FUN_00006608, FUN_0001b418, FUN_00019904]; элемент с флагом 0x20 → Handle 0 и ID из таблицы за её пределом (`0xFF…FF`) [R:FUN_0001d234, дизассемблер]; ядро не находит LD с ID = DeviceID и заводит новую Legacy-LD [R:FUN_0002c130] (дубль 02.11 — 48-битный случайный ID). Пакет операции пишется **до** пересканирования — испорченное попадает на диск со следующей операцией. Условие — зависит от времени (гипотеза; 06.11 три создания на все HDD — без поломки). Проверить: после поломки — Controller Management → Rescan Disks (прогноз: Array 1 снова Normal).

## Открытые вопросы

1. ~~CRC~~ — сумма найдена [D], [J]. Проверить на дампе для `RC_ConfigCommit` и пакета.
2. Что между `0x6000` и `0x105000`; заполняет ли Windows `Start/EndMetaDataSpace`; есть ли что-то в конце диска.
3. Флаги (макросы, в DWARF нет): `Features`, `SpareInfo`, `RC_LogicalDevice.Flags`/`Attribute`/`Cache`, `RC_LogicalElement_LE.Flags`. Источник — дампы и код `rcblob` (там имена функций).
4. Состояния при деградации, пересборке, инициализации, hot spare: какие `State`, `TransformType/State`, флаги элементов; где журнал `RC_TransformLogStruct_LE`.
5. ~~Раскладки~~ — найдены [R]: RAID10 = md `n2`, RAID5 = md `right-asymmetric`, RAID6 = md `right-symmetric` + EVENODD-Q (несовместимо). Проверить на дампах RAID5/6.
6. ~~Дубль LD~~ — `TransformLogicalDeviceLink` [B], [D]. Что лежит во втором LD у живого тома без трансформации — по дампу.
7. Одинаков ли формат для SATA (`43BD`) и NVMe (`B000`) — в RAIDCoreDxe путь один.
8. VOLUME / RAIDABLE / LEGACY на диске.
9. ~~Серийный номер у Windows~~ — тот же `0x859010220000` [X].
10. ~~`GenerationNumber` пакета~~ — на 1 меньше commit [X].
11. Служебная область тома (`AllocatedSpace` + 0…0x5000): формат битовой карты, как AMD отмечает «грязное» завершение — нужно mdmon.
12. `Features` `0x21ED0000` у части дисков [X] — что это.

## Состояния тома: отказ и пересборка (по кольцу X399 [X] и коду rcblob [R])

В кольце X399 (48 пакетов, Windows + BIOS) сохранилась **настоящая деградация и пересборка** RAID10 2×2 — видно сравнением полей тома по всем пакетам (`python` по `tools/amdraid_dump.py`, 2026-10-29):

| Что | Поля | Источник |
|---|---|---|
| норма | `State 0x200`, `Flags 0`, элементы `Flags 0`, `TransformType 0` | [X] (31 пакет) |
| отказ участника | элемент `Flags 0x30` (`0x20` «под подозрением» + `0x10` «отказал») или `0x10`; `State 0x201` CRITICAL; том `Flags 0x2`/`0x20002` | [X], [R:RC_SignalDriveErrorWithLogicalElement, RC_UpdateDriveErrors] |
| два отказа в разных зеркальных парах | элементы 0: `0x30`, 2: `0x10`, `State 0x201` | [X] |
| заменённый диск | PD `DeviceType 0x1202` (NOT_INITIALIZE) или `Features` без старших бит (`0x1c`) | [X] |
| пересборка, начало (member0, посл. 7 и 14) | обе копии LD: `TransformType 0x5358` (`RESTORE_SEGMENTS`), `LastOperation 0x5358`, `TransformState` прежний (`0xA1A6`), `TransformProtectSize 0x8000`, `TransformProtectStart 0`. Источник (`TransformLink 1`): элементы как были — восстанавливаемый слот пуст (ID 0, `0x30`), `Flags 0x20012` (= прежние `0x2` + `0x10` + `0x20000`). Цель: в слоте — новый диск, флаги 0; другой ещё не заменённый отказавший элемент — `0x8010`; `Flags 0x10020002`; `State` — каким станет том (`0x201`, если второй отказ остаётся, иначе с посл. 15 — `0x200`) | [X] |
| пересборка, 100 % (посл. 8 и 17) | `TransformProtectStart` = `Capacity` (`0x9185F6000`), `TransformPercentDone 100000`, `TransformProtectSize 0`; у цели `TransformState 0xA1A1`, у источника `Flags 0x84`. **Промежуточного хода в конфигурации нет** — между началом и 100 % пакетов не пишется (ход — в журнале трансформации тома) | [X] |
| после пересборки (посл. 9 и 18) | одна копия LD (элементы цели, `0x8010` → снова `0x10`), `TransformType 0`, `LastOperation 0x5358`, `TransformState 0xA1A6`, `ProtectStart/Size 0`, `Flags 0`, `State 0x200` (или `0x201`, если остался другой отказ) | [X] |

**Глобальный резерв** [R:RC_CreateTransformDevice, RC_SetupTransform, RC_CheckRebuild], сверено с [W] (`FUN_140026504` — то же, по строке `RC_CreateTransformDevice: Failed…`; REA/Ghidra 12.1.4): пересборка начинается, если том критический, избыточный, нет другой трансформации и есть резерв (`SpareCount` тома, глобальный или распределённый). Глобальный — PD `RAIDCORE_DISK` с `SpareInfo & 0x100`, в сети, ещё не в этом томе; на нём `RC_AllocateSpace` берёт **первый свободный промежуток от `0x100000`** (`RC_Device_Space::BuildFreeList/GetFreeSpace`; заняты экстенты всех LD и их вторых копий) размером `AllocatedSpace` тома; `UserDataSpace` = начало + `0x5000` (`RC_CheckSnap == 0x20000`, иначе `+0x800`), размер — как у остальных; флаги элемента 0. **`SpareInfo` резерва после этого не сбрасывается**: бит `0x100` снимает только команда пользователя (`RC_DeassignPhysicalDeviceGlobalSpare`; в [W] единственное место — `FUN_1400652d0`, сообщение `0x46d`); значит, остаток места на таком диске может уйти и другому тому. Ограничение: резерв должен быть на том же контроллере, что и диски тома (`DevicePrivate[0x3c]`), если в `RC_GetFeatures()` нет `0x8` (маска `RVar & 8` в `RC_CreateTransformDevice` [R]; `RC_GetFeatures` = AND `ControllerFeature` всех контроллеров [R @112231 выгрузки]); `0x8` — «массив на нескольких контроллерах», он есть и в `0x4b`, и в `0x6b`, т.е. на всех известных платформах ограничения нет. `super-amd.c` до 08.11 ограничивал глобальный резерв контроллером тома (ошибочно: «бит 8» прочитан как `1<<8`), с 08.11 — не ограничивает (J 08.11). **На железе [M], 07.11:** после миграции RAIDABLE → RAID1 на глобальный резерв (`mdadm --grow`) меню показывает том RAID1 Normal, а второй диск тома — «Global Spare» (`View Associated Physical Disks`: `2:1:1, SATA, 1.0 TB, Global Spare`): у использованного резерва меню выводит роль по `SpareInfo`, а не «Online».

**Резерв, назначенный в меню** [Q, снимки `09` → `10` → `11`, `blank-sata4`]: Initialize чистого диска — метка `RC_MetaData` (`Features 0x1c`, `+0x34` SpareInfo `0`), PD в пакете на **следующем порту по порядку** (`5` — между SATA 1–4 и NVMe 6–7, список PD отсортирован по `Handle`), `RAIDCORE_DISK ONLINE`, `bus 0x2000`, `features 0x2300`, `spare 0`, конфигурация +1 на всех дисках. Assign Global Hot Spare — тот же PD с `spare 0x100` и метка с `+0x34 = 0x100` (кольцо этого диска переписано с начала: «записей на этот диск 1»). `super-amd.c` (`mdadm --add`, с 03.11) делает оба шага сразу: метка с `0x100`, PD — первый свободный порт, по порядку, `0x2300`/`0x2100` (NVMe), `spare 0x100`; дальше — обычная пересборка на глобальный резерв. Бывший участник (метка этой конфигурации) получает метку с прежним DeviceID и пересобирается в свой слот. ? — PD заменённого диска (его метки больше нет) остаётся в пакете `ONLINE`: что с ним делает прошивка/меню (в [X] у заменённого — `0x1202` NOT_INITIALIZE); проверить на стенде.

**Отсутствующий участник** [R], агент ВМ 2026-11-02, по декомпиляции: `RC_ValidateLogicalElement` @0012f1e0 — у элемента без диска (или с диском из старой конфигурации при SelectGroup) `Flags |= 0x20`, сообщение «logical element offline», Handle → «offline handle»; при первой записи `RC_UpdateDriveErrors` @0012f080 делает из `0x20` — `0x30`. Отказ по ошибке ввода-вывода (`RC_SignalDriveErrorWithLogicalElement` @0013b2c0, после `LicenseToKill`) ставит **только `0x10`**; `RC_UpdateDriveErrors` к `0x20` добавляет `0x10`, `0x20` остаётся. Итого в конфигурации **`0x10` — «отказал», `0x30` — «отсутствовал (offline), том писался без него»** — различимы (проверено по коду 2026-11-02; согласуется с [X]: в одном пакете элемент 0 — `0x30`, элемент 2 — `0x10`; ? — как это показывает меню на железе). `super-amd.c` пока пишет `0x30` в обоих случаях — поправить. На вернувшийся диск AMD сам не пересобирает: экстент участника с offline handle считается свободным (`BuildFreeList`), пересборка — только на резерв или по команде пользователя. `super-amd.c` (с 02.11): отказ отсутствующего пишется до первой записи (`amd_mark_missing`, как IMSM `handle_missing`), вернувшийся устаревший участник — цель пересборки в свой слот и экстент (`RESTORE_SEGMENTS`, как у резерва) — отличие от AMD, сознательное. Проверено на стенде (RAID1 из меню, загрузка без диска → `0x201`/`0x30` → возврат → пересборка → `0x200`, поколение 11, загрузка через RAIDCoreDxe) [Q]; ? — что покажет меню RAIDXpert2/Windows после такой пересборки.

Флаги элемента в памяти [R]: `0x10` отказ (ставится при неустранимой ошибке), `0x20` offline/подозрение (`RC_UpdateDriveErrors` добавляет `0x10` → `0x30`), `0x4000` ошибки ввода-вывода без исключения, `0x8000` отказ зафиксирован в конфигурации (`RC_UpdateCommitDriveErrors`); том критический, если у элемента `Flags & 0xC030` или `State == CRITICAL` (`IsArrayCritical`). Старшие 16 бит — только в памяти (`UpdateElementState`).

**«Грязного» завершения в конфигурации AMD не отмечает**: в 31 пакете нормальной работы X399 и во всех 341 пакетах ASRock (конфигурация переписывается при каждой загрузке) поля тома не меняются. Флаги тома `0x1`/`0x2` — останов ввода-вывода перед сменой конфигурации (`RC_DrainLogicalDevice`, `RC_DrainExitDriver`), только в памяти. Вероятно, после аварии работает битовая карта в служебной области тома: `Attribute` переключается `0x401` ↔ `0x405` (бит 4 — карта/проверка) вместе с `CHECK_BITMAP_REDUNDANCY` (`0x5359`) [X], [R:RC_FlushBitmap]. ? — нужен дамп служебной области тома RAID1/10 (у X399 его нет).

## Журнал трансформации тома (продолжение пересборки после перезагрузки) [R], [B]

Ход трансформации (пересборки, инициализации…) в пакет конфигурации **не пишется** — только в журнал на томе. По нему драйвер ОС продолжает прерванную трансформацию.

- **Где:** логический сектор `Capacity` LD-цели (копии с `TransformLink`) с флагом ввода-вывода `0x10000` → `AllocatedSpace.SectorOffset + 0` элемента столбца `LogicalSector % (chunk × FirstCount) / chunk` = **столбец 0** (Capacity кратна полосе) и копии зеркала `CoreFlags & 0xFF`: запись — на все копии `[0][*]`. Один сектор, значимы первые 0x68 байт (буфер 0x80). [R:RC_Raid10NLogicalToPhysical, RC_TransformDiskLogNextRegion]
- **Формат** `RC_TransformLogStruct_LE` (0x68) [B]: `+0x00` u64 Checksum — стандартная сумма по `+0x08…+0x67` (0x60 байт; `Reserved` у обоих `RC_DeviceIdentifier_LE` при подсчёте = 0); `+0x08` DeviceID LD (u64 ID + Handle) ; `+0x18` TransformType; `+0x1C` u64 TransformProtectStart (**логический сектор тома, до которого сделано**: `NextProtectRegionStart`); `+0x24` u64 TransformIOStart; `+0x2C` u32 TransformIOSize; `+0x30` u32 TransformFlags (у LD; `RESTORE`/`CHECK` ставят `|0x241`); `+0x34` u32 TransformProtectSize; `+0x38` CurrentStripe, `+0x3C` DynamicProtectStripe, `+0x40` LogUpdateStripe; `+0x44` u32 TransformStatus (`0` READY, `1` STARTED, `2` COMPLETED); `+0x48` CopyToDeviceID; `+0x58` CopySectorStart; `+0x60` CopySizeInSectors. [R:RC_TransformDiskLogNextRegion, RC_IsTransformLogValid]
- **Запись:** пока у LD `Flags & 0x10` (сразу после старта) — журнал только с ID, типом, флагами и статусом READY; дальше — полный, статус STARTED (COMPLETED в конце). Очистка — сектор нулей (`CoreFlags 0x20000`). [R:RC_TransformDiskLogNextRegion, RC_ClearLogicalDeviceTransformLog]
- **Действителен,** если сумма верна и `DeviceID ≠ 0`, `TransformType ≠ 0`, `TransformFlags ≠ 0`; при чтении сверяется `DeviceID` с ID тома. Есть ещё журнал «NV» (память драйвера, `RC_GetTaskLog`) — при наличии он предпочтительнее; после загрузки его нет, берётся дисковый. [R:RC_CheckTransformLogs, RC_RestartTask]
- **Продолжение** (`RC_RestartTask`): журнал действителен → у LD `TransformProtectStart/IOStart/Flags/ProtectSize` из журнала, трансформация продолжается с `TransformProtectStart`; журнал недействителен и `TransformType = RESTORE_SEGMENTS` → проверка `RC_CheckRebuildConfiguration` и пересборка **с нуля** (`ProtectStart 0`); `COMPLETED` или `TransformPercentDone = 100000` → завершение. [R:RC_RestartTask]
- **Какую копию читает драйвер AMD** [Q-rcraid 9.3.3-00302, стенд 3, 07.11, `notes/agent-grow-judge2.md` § 3.3, § 4]: копию на элементе **`[0][0]` LD-цели** — не самую новую и не наименьшую (опыт с подменой секторов журнала двух дисков: отметка 40 % на SATA0 → AMD продолжил с 55 %, 0 на SATA0 → с 0). Следствие: пересборка `RESTORE_SEGMENTS` **в слот 0**, у которой цель отсутствовала, пока md писал (mdmon сбросил журнал в 0 только на присутствующих), под AMD продолжалась со старой отметки цели — тихая порча зеркала (R4). У миграции RAIDABLE → RAID1 `[0][0]` — диск RAIDABLE, без которого md том не запускает, — безопасно. mdmon в таком случае пишет и конфигурацию: цель её пропускает и устаревает, AMD («rebuild failed… initiated») и mdmon копируют её с 0 (`amd_target_behind`). Прошивка и драйвер Windows — не проверены (гипотеза: то же ядро RAIDCore, тоже `[0][0]`).
- **Поля I/O журнала при продолжении** [R: RC_RestartTask @00164050, RC_InitTransformInfo @00180560, RC_InitTransformStruct @00192fd0, RC_TransformUpdateNextRegionFromBeginning @0014de00], [Q-rcraid 9.3.3-00302, стенд 3, 07.11, `notes/agent-init-rcraid.md`]: журнал загружен → у LD флаг 0x800, размер I/O берётся из `IOSize` журнала (`RC_SetTransformSize` не вызывается). Пересборка и миграция пересчитывают его в начале каждого региона (`RC_MaxDynamicTransformIoSize`), **CREATE (0x5355), CHECK (0x5356), CHECK_BITMAP (0x5359) — нет**: инициализация с `IOSize = 0` стоит на месте, регион у отметки остаётся защищённым, ввод-вывод в него — таймауты, элемент отказывает, том «gone critical» (так было с журналом mdmon до 07.11). Как пишет AMD журнал инициализации RAID1 (меню, `rcadm -C`): `IOStart = ProtectStart`, `IOSize` 0x100, `DynamicProtectStripe = LogUpdateStripe = ProtectSize / полоса` (0x90), флаги — из LD (0x211 у меню, 0x241 у `rcadm -C`; биты 0x10/0x40 rcblob не проверяет). RAID10 — `IOSize` = блок (по `RC_SetTransformSize`, на стенде не проверено). **Журнал RAID5 и CREATE `rcadm -C` [Q-rcraid 07.11, `notes/agent-judge3.md` §3]:** у RAID5 AMD пишет журнал через логику RAID5 — в элемент данных строки 0 «полосы за концом» сам журнал, в элемент чётности — чётность (RMW, побайтно по образам), читает элемент данных (какой из `[0,0]`/`[0,1]` — по `полос % s`); для R4 у RAID5 опасна цель именно в элементе данных журнала; mdmon пишет одинаковую копию в оба — AMD не мешает. Журнал CREATE `rcadm -C`: RAID10 и RAID5 — IOSize = блок, флаги 0x241 (флаги LD), ProtectSize 0x8000/0x9000, Dyn/Log 0x80/0x90 — подтверждает `RC_SetTransformSize`; при выключении rcraid пишет «create task has shutdown» и журнал с отметкой. **rcraid.sys 9.3.3.218 [W-ВМ 07.11, `notes/agent-winjudge2.md`]:** продолжает инициализацию RAID1 и RAID5 по журналу mdmon с отметки (выше неё RAID1 выравнивает `[0][1] → [0][0]`); с `IOSize = 0` в журнале CREATE — CRITICAL, `[0][1]` 0x10, I/O тома висит (как rcraid Linux); журнал при пересборке читает с `[0][0]` LD цели; если на `[0][0]` сектор журнала пуст, а пакет говорит «пересборка», — завершает её без копирования (зеркало несогласовано, том NORMAL; mdmon такого не создаёт: журнал пишется до пакета); после пересборки ставит `CHECK_BITMAP_REDUNDANCY` (зачем — не выяснено); при CREATE пакеты с 2 LD, State 0x200.
- **Пакеты хода трансформаций у rcraid.sys 9.3.3.218** [W-ВМ 08.11, `notes/agent-winjudge3.md` §3]: `TransformState 0xA1A7` (NOT_COMPLETED; rcraid Linux и mdmon пишут `0xA1A6`), флаги LD источника `0x20426`/`0x20626`; после работы Windows у LD тома остаётся `Flags 0x20002` (смысл `0x2` не выяснен; наш mdadm собирает без resync); журнал пересборки RAID10 — IOSize `0x400`, Dyn/Log `0x20` (mdmon — нули, AMD их пересчитывает); диски, последний раз бывшие онлайн на другом драйвере (rcraid Linux), Windows импортирует и нумерует кольцо заново с seq 0. Обе стороны читают пакеты друг друга. Журнал миграции RAIDABLE → RAID1 у mdmon и Windows побайтно равен, кроме суммы, отметки и `DeviceHandle`.
- **Инициализация (`CREATE_REDUNDANCY` 0x5355) — тот же журнал и тот же механизм** (по коду, 2026-11-02): движок трансформаций общий (`RC_TransformLogicalDevice` @00180ce0 — для CREATE идёт `RC_ScrubRaid10NextRegion`/`RC_ScrubRaid50NextRegion`, ход — по регионам `NextProtectRegionStart`), журнал пишут `RC_TransformDiskLogNextRegion` @00180740 и `RC_SetTaskLog` @00163de0 без ветвления по типу: `TransformType`/`TransformFlags` — из LD (у тома из меню и `mdadm -C` — `0x211`), `TransformProtectStart` = `NextProtectRegionStart`; при старте `RC_InitTransformStruct` @00192fd0 берёт начало из журнала для любого типа (`LD.Flags & 0x800` — журнал загружен; у `CREATE_ZERO`/`SECURE_ERASE` — ещё счётчики обнуления), `RC_RestartTask` @00164050 сверяет ID/тип/статус STARTED. Остановка CREATE при ошибке — `TransformState` STOPPED (не REMOVED, как у проверок). [R] Пишет ли драйвер при старте CREATE пакет конфигурации (смена `TransformState` 0 → STARTED) — **не выяснено** (гипотеза: нет, ход только в журнале); mdmon пакет при старте не меняет, только журнал. Как у пересборки: в начале не проверено драйвером Windows. mdmon (`super-amd.c`): по контрольным точкам md resync (каждые 1/16 тома или 5 мин) — журнал `CREATE_REDUNDANCY`, STARTED, `ProtectStart` = сектор тома; по окончании (пакет с COMPLETED записан) — очистка; при сборке — **продолжение с отметки журнала всегда, пока инициализация не завершена** (как `RC_RestartTask`; с 03.11 — после ошибки на ПК: перезагрузка с корнем на RAID5 не останавливает массив, карта AMD остаётся «грязной», и прежнее правило «только при чистой карте» начинало resync с нуля); если в карте стоят не все биты (так их ставит драйвер AMD), — с меньшего из «отметка журнала» и «первый бит × Cover». Оговорка: после настоящей аварии полосы ниже отметки, писавшиеся в момент сбоя, повторно не проверяются (write hole RAID5; драйвер AMD закрывает это картой, mdmon не знает, куда писал md) — мера: `md check` после инициализации. Пока инициализация не завершена, незавершённость сама по себе карту не пачкает (её видно по трансформации в LD).
- ? — на дисках не видели (у X399 служебной области тома нет в дампе); как AMD трактует `IOStart/IOSize` и `*Stripe` у RAID10 — проверять с драйвером Windows.

## Битовая карта записи тома (write-intent) [R], сверено с [W] — `rcraid.sys` 9.3.3-00291

Источники: **[R]** `rcblob` (имена функций), **[W]** Windows `rcraid.sys` (`references/amd-windows-raid-9.3.3-00291/`, функции найдены по отладочным строкам и константам), **[D]** UEFI. На дисках не проверено (нет дампа служебной области RAID1/10).

- **Есть ли:** `RC_LogicalDevice.Attribute` бит `0x1` — у тома есть карта (ставит `RC_SetupLogicalBitmap`); бит `0x4` — в карте есть установленные биты, нужна проверка. [R:RC_SetupLogicalBitmap, RC_ConfigBitmap] X399: `0x401` в норме, `0x405` при `CHECK_BITMAP_REDUNDANCY` [X]. ASRock RAID0: бита `0x1` нет — у RAID0 карты нет [A].
- **Где:** один экземпляр, на **элементе `[0][0]`** тома, LBA `AllocatedSpace.SectorOffset + 0x80` (флаг ввода-вывода `0x200000`). Если элемент `[0][0]` вне строя (`Flags & 0x4030`) — ввод-вывод карты не выполняется. Рядом: `+0` журнал трансформации, `+2` журнал фоновой проверки (тоже только на `[0][0]`, см. [A]). [R:RC_Raid10NLogicalToPhysical, RC_Raid50/60LogicalToPhysical]
- **Размер:** `RC_BitMapSize(Capacity)`: `P` = наименьшая степень двойки ≥ `Capacity`, не меньше `0x200000`; если `P ≤ 2^43` секторов — **512 байт (4096 бит)**, для огромных томов больше. [R], [W:FUN_140062900]
- **Бит:** номер `i = LBA тома / Cover`, байт `i >> 3`, маска `1 << (i & 7)`; ставятся все биты от `start / Cover` до `(end−1) / Cover`. [R:RC_SetMemLogicalBitmap64]
- **Cover** (секторов на бит) [R:RC_BitCoverSize], [W:FUN_140062794]: `c = max(P / (8 × размер карты), 0x32000, Protect)`, округлить вверх до кратного `Protect`, затем до кратного полной полосы (`chunk × данных_в_наборе × FirstCount`), не больше `Capacity`.
  `Protect` (`RC_TransformProtectSize`, источник = цель) = `min(данных × FirstCount × 0x4800, 0x8000)` секторов (для RAID5/6 без потолка `0x8000`); `данных` — `RC_SecondElementCount`: RAID10N → 1, RAID5 → `N−1`, RAID6 → `N−2`.
  X399 (39 063 609 344 сект.): `P = 2^36`, `P/4096 = 16 777 216`, `Protect = 0x8000` (совпадает с `TransformProtectSize` копии-цели в кольце [X]) → **Cover = 16 777 216 секторов (8 ГиБ на бит)**, 2329 бит.
- **Когда ставится/снимается:** перед записью данных `RC_GenericIoSplit` → `RC_SetLogicalBitmap`: биты участка в памяти + запись **всей** карты (512 Б) на диск; снимаются лениво — `RC_ClearTouchedMaps` / `RC_FastClearTouchedMaps` (участки, которых давно не касались), `RC_ExitTransformClearBitmaps`. [R], [W: строки `RC_SetLogicalBitmap: …`, `RC_FastClearTouchedMaps: …`]
- **После загрузки:** `RC_ConfigBitmap` читает карту, если потерян кеш (`RC_CacheLost && RC_IoLogLost` — холодный старт) или `Attribute & 4`; есть установленные биты → `Attribute |= 4` → трансформация `CHECK_BITMAP_REDUNDANCY` (`0x5359`) по этим участкам. [R], [W:FUN_14001bf50 со строкой `RC_ConfigBitmap: …`]
- **UEFI** карту не ведёт (строки `CHECK_BITMAP`/`FLUSH_BITMAP` — только для показа состояния в меню). [D:FUN_00003ef0]

**Для mdmon:** «том грязный» = поставить биты (всё или участки) в карте AMD и записать её; «чистый» = очистить карту. `super-amd.c` (с 03.11): пока md может писать — все биты (куда пишет md, mdmon не знает; родной md после аварии тоже начинает с 0); пока идёт resync после аварии и md чист (`clean`, записей в полёте нет) — биты **от отметки resync** (`last_checkpoint` монитора, сектора тома) до конца: уже пройденное согласовано; при сборке resync начинается с `первый бит × Cover` (биты AMD после аварии под Windows — тоже: с первого установленного до конца, с запасом). Проверено на ВМ (vm-test 7б), не на прошивке/драйвере. Тогда после сбоя Linux AMD (Windows-драйвер) сам проверит отмеченные участки, а mdadm при сборке, увидев биты в карте, запустит resync. Обратное тоже работает: после сбоя Windows mdadm увидит биты AMD. ? — проверить на дампе служебной области RAID1/10 и на железе.

### Карта md в служебной области тома (наш формат, не AMD; mdadm с 08.11)

Источник — `super-amd.c` (агент bitmap-amd, `notes/agent-bitmap-amd.md`); место выбрано по `notes/agent-bitmap-space.md` (AMD пишет в служебную область только `+0`, `+2`, `+0x80`, `+0x600…` — [R]/[W]/[D], [Q-rcraid], [W-ВМ], [Q], дампы HDD). Проверено: vm-test этапы 17, 20 [VM]; на железе — HDD и SSD RAID1, авария (`tested.md`); судьи rcraid/Windows [Q-rcraid], [W-ВМ].


Сектор `AllocatedSpace.SectorOffset + 0x100` каждого элемента тома (RAID1/RAID10/RAID5), little-endian; сектора `+0x101…+0x107`
— нули; биты md — с `+0x108`, бит `i` — байт `i/8`, маска `1 << (i % 8)` (как пишет ядро без `BITMAP_HOSTENDIAN`), бит на
`chunk` секторов «синхронизации» md (RAID1, RAID5 — сектора участника, RAID10 — тома), до `+0x600`.

| смещение | размер | поле | значение |
|---|---|---|---|
| 0x00 | 8 | `checksum` | сумма RAIDCore (`amd_sector_sum`, как у `RC_MetaData`) по 0x08…0x1FF |
| 0x08 | 8 | `magic` | `"mdadmWIB"` |
| 0x10 | 4 | `version` | 1 |
| 0x14 | 4 | `chunk` | секторов на бит, степень двойки (≥ 131072 = 64 МиБ, если не задан `--bitmap-chunk`) |
| 0x18 | 8 | `volume_id` | ID LD (`RC_LogicalDevice.ID`) — не заголовок удалённого тома на том же месте |
| 0x20 | 8 | `bits_lba` | абсолютный LBA бит = `AllocatedSpace + 0x108` = `md/bitmap/location` |
| 0x28 | 8 | `sync_sectors` | что покрывают биты: `resync_max_sectors` md (RAID1, RAID5 — участник, RAID10 — ёмкость тома) |
| 0x30 | 8 | `generation` | `GenerationNumber` конфигурации AMD, которую mdmon последней записал или застал |
| 0x38 | 8 | `config_checksum` | `CommittedChecksum` (сумма заголовка пакета) этой конфигурации |
| 0x40 | 4 | `amd_bitmap` | что mdmon делает с картой AMD в этом сеансе (с 09.11, review-fix): `k` — «чисто или грязно от бита `k` до конца» (одно значение на сеанс: переход clean↔active заголовки не переписывает; переписываются при смене конфигурации, сдвиге `k` в resync и останове), `0xFFFFFFFF` — только чисто (mdmon оставил так при останове массива), `0xFFFFFFFE` — не знаем (нет [0][0] или не mdmon), `0xFFFFFFFD` — md битов не ведёт (ядро не взяло карту) — не принимается никогда |
| 0x44 | 0x1BC | — | нули |

`-E` участника показывает: `md Bitmap : 65536 KiB a bit, 3 of 16 set (this disk), at 1048840` и
`md Bitmap mdmon : AMD generation 12, AMD bitmap clean | clean or dirty from bit 0 | not mdmon's or not read | md kept no bits: bits not trusted`.

**Windows с картой md** [W-ВМ, `notes/agent-bitmap-win.md` § 7]: rcraid.sys 9.3.3.218 в `[AS+0x100, +0x600)` не пишет; карту AMD (`+0x80`) ставит шире записи — запись 8 МиБ в 1500 МиБ тома 2 ГиБ → биты 9..18 (бит 100 МиБ), у томов ≤ 768 МиБ — все биты; после аварии выравнивает зеркала только под битами карты AMD, копируя `[x][1]` → `[x][0]`, карта обнуляется за ~20 с (в `rcadm -M -qa` задачи не видно); пересборка на пустой глобальный резерв кладёт элемент в первый свободный промежуток от 0x100000 и служебную область нового диска не пишет (нули).

**Windows: роли резервов и отставший диск** [W-ВМ, `notes/agent-spares-win.md` § 3]:
- **Windows роли резервов из PD/метки сохраняет как есть**: участник без `0x100` — не резерв («G S» «-»), глобальный резерв
  — «Y»; после выключения PD и метки те же (1a, 1b). Участник, на который пересобирали том, сохраняет `0x100` и в Windows
  (2a′, 2b) — как `tested.md` § 1. [W-ВМ]
- **Диск со старым пакетом при загрузке Windows** (2c): Windows берёт конфигурацию с большим поколением; элемент этого
  диска в томе (failed по живому пакету) заменяет пустым слотом — PD-индекс `0x8FFF` (в `--brief` `36863:0000`), флаги
  элемента `0x30` вместо `0x10`, место на диске освобождается (весь диск свободен). При догнанном пакете (2a) — элемент
  остаётся `0x10` (failed), место занято; освобождает его только `rcadm -M -id`. [W-ВМ]
- **PD OFFLINE для присутствующего диска** (пакет mdmon после отказа и догоняющей записи) Windows при загрузке молча делает
  ONLINE и пишет следующей конфигурацией (2a, 2b). [W-ВМ]
- **`rcadm -M -ags` на диск с failed-элементом** отказывает («already part of array N»); `-id` снимает элемент, после `-ags`
  пересборка начинается сразу (2a′). Сама Windows резервом его не назначает. [W-ВМ]

### SSD и HDD в драйвере AMD (rcblob 9.3.3, по декомпиляции; 2026-11-02)

- Тип носителя **в метаданных не хранится**: `PortType` PD на диске = 0 во всех дампах (MSI HDD, ASRock NVMe, X399 SATA); драйвер заполняет его в памяти сам. «SSD-массив» — у всех участников бит `0x800` `PortType` в памяти (`RC_CoreLogicalDevice::IsSolidStateArray` @0012e070). [rcblob]
- Для SSD-массива: свой размер «закрепления» чтения за зеркалом (`RC_RAID1_AffinityLockSizeSSD`, `RC_MapMirrorRead`); поток для упреждающего чтения — с 140 обращений вместо 5 (`RC_DoStreamActivate`); для одиночных чтений бит read-ahead снимается (`RC_SetCacheStrategy`, гипотеза); у RAID5 нет «parity toss». [rcblob]
- TRIM/UNMAP (`RC_HW_SATA_TrimDisk`, `RC_HW_SCSI_UnmapDisk`): только RAID0/1/10, Volume, Legacy (не RAID5/6, `RC_IsTrimAllowed`), не во время трансформации; у зеркал — только если все диски дают нули после TRIM (`RC_DeterministicTrimZeroCount`, `RC_CheckLogicalDeviceTrimable`). md передаёт discard зеркалам всегда — на SSD без DZAT «Check» драйвера AMD может найти расхождения в пустом месте. [rcblob]
  - **Признаки диска** (`RC_HW_SATA_IdentifyComplete` @00118150): `PortType |= 0x100000` «TRIM есть», если IDENTIFY сл. 169 **== 1** (всё слово); `|= 0x400000` «нули после TRIM», если сл. 69 бит 5 (RZAT; бит 14 DRAT не смотрит). `RC_TrimCount` @0018c6c0 считает `0x100000`, `RC_DeterministicTrimZeroCount` @0018c760 — `0x400000`. **Для NVMe в rcblob 9.3.3 ни один из битов не ставится нигде** (единственное место — SATA) → Linux-драйвер AMD зеркала на NVMe не TRIM-ит никогда (драйвер Windows — не проверено). [rcblob]
  - **Что драйвер сообщает системе** (`RC_UpdateLogicalDeviceIdList` @00192820 → `RC_CheckLogicalDeviceTrimable` @0018c800, флаг 2 в списке LD): RAID1 (`RAID10N` First=1, Second>1) — если нули после TRIM у всех; RAID0 (First≥2, Second=1), Volume, RAIDABLE — если TRIM умеют все; Legacy — если умеет диск; **RAID10 (First≥2, Second≥2) и RAID5 — никогда**. Пропуск самой команды (`RC_IsTrimAllowed` @001544f0): RAID50/60 — нет; RAID10N с Second>1 — только при нулях у всех. [rcblob]
  - **`super-amd.c`** (`amd_limit_trim`): RAID5/6 — без TRIM; RAID1/10 — без TRIM, если хоть один участник не даёт нулей (SATA: сл. 169 бит 0 + сл. 69 биты 14 и 5; NVMe: DLFEAT = 001b). Отличия от AMD — в безопасную сторону или безвредны: RAID10 и NVMe-зеркала с нулями у всех TRIM получают (обе копии читают нули — расхождений для «Check» нет); бит DRAT требуем дополнительно (по ACS RZAT без DRAT не определён). Решение mdmon пишется в dmesg (`mdmon: amd: TRIM off on mdN …`; stderr у mdmon — `/dev/null`, `manage_fork_fds`).
  - **Железо (04.11):** XPG MARS 980 BLADE (fw Y0508B) — DLFEAT `0x01` (нули), ONCS `0xd7` (DSM есть, Write Zeroes нет) → `amd_trim_zeroes` = да [ПК, `tools/nvme_dlfeat.py`]. HDD HGST HTS541010B7E610 (sda, sdd) заявляют TRIM и DRAT **без RZAT** (hdparm: «Deterministic read data after TRIM», без «zeroed»), Linux даёт им discard; Seagate ST1000LM035 и HGST HTS721010A9E630 — без TRIM. На ПК у всех зеркал HDD-контейнера `discard_max_bytes = 0`, у RAID0 sdc+sdd — 2 ГиБ. Ядро само у зеркала со смешанными участниками TRIM не выключает (ВМ 6.12, обычный md: loop + scsi_debug без TRIM → `discard_max` loop) — значит, выключил mdmon. **Подтверждено на ПК (04.11, пакет `-13`):** у зеркал HDD `discard_max_hw_bytes` 2 ГиБ, `discard_max_bytes` 0, в dmesg по строке `mdmon: amd: TRIM off on mdN …` (зеркала — «a member does not read zeroes», RAID5 — «a parity volume»); RAID1 sdb+sdc — `hw` 0 (TRIM нет ни у кого). Ядро 7.3, как и 6.12, берёт у зеркала ненулевой минимум. HTS541010B7E610 — по-видимому, SMR (TRIM освобождает полосы, нулей не обещает).
- Меню MSI: «Select Media Type: HDD/SSD» на экране выбора дисков (IFR формы 0x211/0x212, varstore 0x8010 +0x2C4) — по месту фильтр списка дисков; пишет ли что-то в метаданные — не проверено. [D]
