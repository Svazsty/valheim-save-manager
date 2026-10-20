# Jak działa synchronizacja

## Jeden silnik

GUI i menu konsolowe w `ValheimSaveManager.ps1` wywołują `Invoke-WorldSync` z `engine/Sync.ps1`. Nie istnieją osobne mechanizmy kopiowania dla obu interfejsów. WPF wykonuje operacje w osobnym runspace, a DispatcherTimer odbiera etap i wynik bez blokowania okna.

## Upload

1. Blokada lokalnej operacji i sprawdzenie, czy gra jest zamknięta.
2. Kontrola kompletu świata i ostatniego znanego archiwum (`lastSeenArchive`). Niepobrana gałąź blokuje wysyłanie.
3. Porównanie ze znanym ZIP-em oraz snapshot/hash lokalnych plików przed i po skopiowaniu całego świata do TEMP.
4. Utworzenie manifestu v1 i ZIP-a. Ponowne otwarcie, CRC32 i porównanie zawartości.
5. Kopia do własnego `.uploading` w Drive, kontrola SHA-256 i ponowne sprawdzenie procesu gry oraz wersji Drive.
6. Publikacja przez rename do `.zip` bez nadpisywania istniejącego pliku, a następnie zapis lokalnego stanu/historii.

Niepowodzenie zapisu stanu po publikacji jest raportowane osobno: ZIP może już znajdować się w folderze Drive. Aplikacja nie zgłasza potwierdzenia synchronizacji chmurowej.

## Download

1. Jawne potwierdzenie użytkownika oraz wspólna blokada operacji.
2. Kopia najnowszego ZIP-a do TEMP; weryfikacja ścieżek wpisów, CRC32, manifestu i kompletu wybranego świata.
3. Sprawdzenie, czy import nie cofnie nowszego lokalnego zapisu.
4. Kopia świata z ZIP-a do stagingu na woluminie `worlds_local` i porównanie SHA-256.
5. Jeśli świat istnieje: pełny backup pod nazwą `.partial`, weryfikacja i dopiero potem rename na finalną nazwę backupu.
6. Ponowne sprawdzenie procesu gry, lokalnego świata i najnowszego archiwum.
7. Dziennik transakcji `prepared`; rename lokalnego świata do sąsiedniego katalogu poprzedniej wersji, rename stagingu na nazwę świata, zapis stanu i oznaczenie `committed`.
8. Sprzątanie wyłącznie własnych katalogów roboczych. Błąd przed zatwierdzeniem przywraca poprzedni katalog i stan.

Po przerwaniu procesu następna operacja przy zamkniętej grze odczytuje dziennik: niezakończony import jest wycofywany, a zatwierdzony ma dokończone sprzątanie. Nieprawidłowy dziennik blokuje automatyczne odzyskiwanie i zachowuje katalogi do kontroli.

## Format archiwum

```text
VALHEIM_<świat>_<yyyyMMddTHHmmssfffZ>_<komputer>.zip
├── manifest.json
└── world/
    └── <świat>/
        ├── _main.N.ok
        ├── _main.N.db2
        ├── _main.N.fwl2
        ├── _main.N.chunks
        └── ...pozostałe pliki całego świata
```

Manifest zachowuje format pierwotnego skryptu:

```json
{
  "version": 1,
  "worldName": "NewWorld",
  "createdUtc": "2026-10-20T12:00:00.0000000Z",
  "sourceComputer": "HOST"
}
```

Do ZIP-a nie dodajemy postaci, configu, historii ani backupów aplikacji. Nazwa komputera znajduje się w nazwie ZIP-a i manifeście, zgodnie z pierwotnym formatem — udostępniaj archiwa tylko zamierzonym uczestnikom wspólnego folderu.

## Granice ochrony

Plikowa blokada chroni operacje korzystające z tego samego lokalnego katalogu danych aplikacji. Nie jest rozproszoną blokadą pomiędzy komputerami. Google Drive może pokazać zmianę z opóźnieniem. Kontrola procesów jest ponawiana przed podmianą, ale grę nadal trzeba pozostawić zamkniętą do końca operacji.

Komplet plików nie dowodzi poprawności semantycznej binarnego zapisu Valheim. Hash i CRC32 wykrywają rozbieżność/uszkodzenie kopiowanych danych, a nie błędy, które istniały już w źródłowym świecie. Odzyskiwanie transakcji nie zastępuje niezależnego backupu i nie jest gwarancją odporności na awarię sprzętu.
