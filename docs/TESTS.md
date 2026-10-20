# Testy i zakres dowodów

Środowisko: Windows, Windows PowerShell **5.1.26100.9711**, natywny WPF/.NET Framework. Wszystkie operacje kopiowania używają sztucznych światów; nigdy nie nadpisywano prawdziwego świata ani danych postaci.

Wynik lokalny z 20.10.2026: **26/26 testów silnika oraz 22/22 kontrole WPF/launchera**. Testy silnika obejmują dodatkowo pierwszy import do folderu z samym cache, zachowanie backupu tego folderu, ochronę nowszego niepełnego zapisu oraz odrzucenie cache-only ZIP-a. Testy WPF wymuszają długi komunikat, kontrolują brak przewijania poziomego, rzeczywistą szerokość paska 12 jednostek i działanie pionowego przewijania. Podgląd tego stanu: [ciemny pasek](images/scrollbar.png).

Test `Test-Gui.ps1 -Launcher -SuppressedWorkerDiagnostic` dodatkowo wprowadza faktycznie tłumione wyszukanie nieistniejącego procesu na poziomie skryptu workera. GUI ma respektować zwrócony wynik nawet przy `PowerShell.HadErrors=true`. Samo wyszukanie procesu wewnątrz oryginalnej funkcji nie odtworzyło zgłoszonej awarii, więc nie jest uznawane za ustaloną przyczynę problemu konkretnego użytkownika. Próba ręcznego testu natywnego potwierdzenia została przerwana; jego zachowanie na komputerze zgłaszającym problem pozostaje niezweryfikowane.

## Automatyczna weryfikacja

`tests/Test-Engine.ps1` obejmuje konfigurację i migrację starego JSON, uszkodzony JSON, niedozwolone nazwy i nakładanie ścieżek, brak świata, cache-only, komplet jednej generacji i pusty marker ok, brak Drive, zły ZIP, upload/download z polskimi znakami i spacjami, zachowanie formatu v1 i izolacji postaci, niepobraną gałąź, starszy upload, nowszy lokalny świat, weryfikację backupu, błąd kopiowania, rollback po błędzie stanu już po instalacji, odzyskanie przerwanego importu, blokadę równoległej operacji, symulowaną oraz rzeczywistą kontrolę procesu gry, ZIP traversal/duplikaty/inny świat, uszkodzoną CRC32, sprzątanie nieudanego `.uploading`, błąd backupu oraz historię porażki bez utraty poprzedniego sukcesu.

`tests/Test-Gui.ps1 -Launcher` używa rzeczywistej ścieżki CMD → WScript → PowerShell STA → WPF w kopii testowej. Sprawdza widoczność natywnego okna i brak widocznej konsoli, rozwiązywanie Onest, status z runspace, przejście do Settings, odrzucenie złych ustawień, zapis dobrych, blokady kontrolek i zamknięcia podczas pracy, realny upload sztucznego świata przez przycisk, komunikat o niepotwierdzonej chmurze, realny download przez worker z potwierdzeniem dostarczonym przez test, zachowanie bajtów i backup, historię oraz minimalizację/maksymalizację/przywrócenie.

W kopii testowej GUI zamockowano wyłącznie zapytanie o proces gry, ponieważ prawdziwy Valheim działał podczas prac. Produkcyjny silnik pozostaje bez tego mocka. Produkcyjny detektor gry jest sprawdzany osobno na sztucznym świecie.

PNG 100% i 150% powstają z natywnego RenderTargetBitmap WPF, bez HTML lub makiety. Render 150% nie jest dowodem fizycznej zmiany monitora/DPI. Testy GUI wywołują zdarzenia WPF wewnątrz dispatchera; nie są dowodem użycia fizycznej myszy ani klawiatury. Interfejs potwierdzenia downloadu pozostaje natywnym Yes/No z domyślnym No; test workera dostarcza potwierdzenie bez automatycznego klikania tego dialogu.

Po lokalnym uruchomieniu testów dokładny raport powstaje w `test-results/engine.json` oraz `test-results/launcher.json`. Raportów i sztucznych światów nie śledzimy w Git.

## Pozostałe testy ręczne

1. Uruchom launcher dwuklikiem. Sprawdź widoczność okna, brak konsoli PowerShell i Onest. CMD może pojawić się na ułamek sekundy przy jego uruchamianiu; bezpośredni dwuklik VBS pomija CMD.
2. Przeciągnij okno za pasek tytułu, zmień rozmiar, sprawdź Tab/Shift+Tab, Enter/Spacja, Ctrl+,, Esc i Alt+F4. Sprawdź różne DPI/monitory. Nie wykonuj synchronizacji na prawdziwym świecie w tym kroku.
3. Do bezpiecznej próby klikanej uruchom `tests/Start-GuiSandbox.ps1`. Okno używa sztucznego świata oraz osobnej konfiguracji. Z działającą grą operacja powinna być blokowana. Zamknij grę samodzielnie, jeśli chcesz sprawdzić operacje na fixture'ach.
4. Na fixture'ach sprawdź natywny dialog potwierdzenia: No nie wykonuje importu, Yes uruchamia import i zostawia backup. Dopiero osobno zdecyduj o próbie z kopią prawdziwego świata.
5. Po wyraźnej zgodzie właściciela wykonaj próbę prawdziwego formatu zapisu oraz wymiany przez rzeczywisty Google Drive między komputerami. Porównaj kopie i sprawdź otwarcie świata w Valheim. Te testy nie były wykonane.

Nie wykonano fizycznego testu z prawdziwym światem, cloud roundtrip, testu ZIP ponad 4 GB ani awarii zasilania. Symulacja przerwanej transakcji sprawdza mechanizm odzyskiwania; nie dowodzi odporności na uszkodzenie sprzętu.
