# Budżet: aplikacja iOS do automatycznego budżetu miesięcznego

Aplikacja na iPhone'a (Swift, SwiftUI), która zamienia wyciąg z konta i zdjęcia paragonów w czytelny budżet miesięczny: ile wydałam w której kategorii, ile zarobiłam, ile odłożyłam i czy wyszłam na plus. Wszystkie dane zostają **na telefonie**.

Powstała z mojej własnej potrzeby. Przez rok prowadziłam budżet ręcznie w Excelu: zbierałam paragony, porównywałam je z wyciągiem, wpisywałam gotówkę i na koniec miesiąca robiłam tabelę przestawną. Aplikacja automatyzuje całą tę procedurę.

> Autor: Alicja Staigl

## Co robi aplikacja

**Import i porządkowanie wyciągu**
- Wczytuje wyciąg z banku w pliku CSV i dzieli go na miesiące.
- Sama rozpoznaje operacje, które **nie są ani stratą, ani zyskiem**, i pomija je w podsumowaniu: wpłaty gotówki we wpłatomacie, przelewy na konto oszczędnościowe, płatność i jej zwrot, przelewy tej samej kwoty w dwie strony.
- Przy przelewach od i do osób pyta jednym tapnięciem: zwrot za wydatek, przychód czy pominąć. Zapamiętuje wybór dla danej osoby.

**Kategorie, które się uczą**
- Kategorie są **własne**, nie narzucone przez bank. Po jednej poprawce aplikacja zapamiętuje, że dany sklep to dana kategoria.
- Podobne nazwy łączą się same (np. „gra” i „gry” albo „ubezpieczenie laptop” i „laptop ubezpieczenie”). Pozostałe można scalić ręcznie.
- Aplikacja uczy się też z mojego starego Excela: wczytuje historię i na jej podstawie przypisuje kategorie nowym operacjom.

**Skanowanie paragonów**
- Aparat jako skaner dokumentów (sam przycina i prostuje paragon) albo zdjęcie z biblioteki.
- Rozpoznawanie tekstu działa **na urządzeniu** (Apple Vision): data, suma i pozycje.
- Pozycje są przypisywane do kategorii. Jeden paragon może więc trafić do kilku kategorii naraz (np. jedzenie i kosmetyki z jednych zakupów).
- Paragon kartą jest dopasowywany do płatności z wyciągu (ta sama kwota, data do 3 dni różnicy) i dzieli ją na kategorie. Paragon gotówkowy od razu dodaje wydatki.

**Gotówka i przychody spoza konta**
- Ręczne dodawanie wydatków i przychodów gotówkowych (np. napiwki) z własną kategorią.
- Przychody są liczone według kategorii i miesięcy, nie tylko jako jedna suma.
- Wpisy z Excela, których nie ma na wyciągu, mogą być dodane automatycznie.

**Analiza**
- Podsumowanie miesiąca: przychody, wydatki, zysk lub strata, oszczędności, rozbicie na kategorie.
- Porównanie miesięcy na wykresie (Swift Charts).
- Limity na kategorie z ostrzeżeniem od 80% wykorzystania.
- Wykrywanie stałych opłat, rozliczenia z ludźmi (kto komu wisi), cele oszczędnościowe z paskiem postępu.
- Ręczny podział płatności na kategorie, edycja i usuwanie zapamiętanych zasad, eksport do CSV (np. do tabeli przestawnej w Excelu).

## Czym różni się od bankowych podsumowań wydatków

Banki oferują proste zestawienia wydatków. Ta aplikacja rozwiązuje to, co przy takich zestawieniach zwykle zostaje ręczną pracą. (Opis dotyczy typowych rozwiązań bankowych, funkcje różnią się między bankami.)

| Obszar | Typowe podsumowanie w banku | Ta aplikacja |
|---|---|---|
| Kategorie | Predefiniowane, przypisywane na podstawie sklepu. Zmiana bywa ograniczona. | Własne kategorie, uczone z moich poprawek i z historii z Excela. |
| Jeden paragon, wiele kategorii | Jedna płatność to jedna kategoria. | Płatność dzielona na kategorie według pozycji z paragonu. |
| Gotówka | Widzi tylko to, co przeszło przez konto. | Wydatki i przychody gotówkowe (ze skanu paragonu albo ręcznie) liczone razem z kontem. |
| Operacje „neutralne” | Wpłaty, przelewy własne i zwroty mogą zaburzać sumy. | Reguły pomijają to, co nie jest stratą ani zyskiem, a ja decyduję w niejasnych przypadkach. |
| Zwroty od znajomych | Traktowane jak przychód albo szum. | Można przypisać zwrot do konkretnej kategorii wydatku i zmniejszyć ją o tę kwotę. |
| Zysk, strata, oszczędności | Zwykle wydatki w kategoriach. | Przychody, wydatki, bilans i odłożone oszczędności osobno, miesiąc po miesiącu. |
| Przychody | Zwykle jedna suma wpływów. | Przychody według kategorii (wypłata, rodzice, napiwki i inne). |
| Prywatność | Dane w systemie banku. | Wszystko lokalnie na urządzeniu. Aplikacja nie wysyła danych na żaden serwer. |
| Eksport | Ograniczony albo brak. | CSV gotowy do tabeli przestawnej. |

## Jak to działa technicznie

- **Język i UI:** Swift, SwiftUI, Swift Charts. Minimalna wersja systemu: iOS 17.
- **Architektura:** jeden obiekt stanu (`Store`, `ObservableObject`) udostępniany widokom przez `EnvironmentObject`. Logika jest oddzielona od widoków.
- **Dane:** modele `Codable` zapisywane lokalnie w pliku JSON. Wczytywanie jest odporne na zmiany schematu (nowe pola są opcjonalne przy odczycie).
- **Import wyciągu:** własny parser CSV (cudzysłowy, separatory `,` i `;`, kodowanie UTF-8 i Windows-1250). Kolumny są rozpoznawane po nazwach nagłówków, a opis operacji (sklep, tytuł, data wykonania) jest wyciągany wyrażeniami regularnymi.
- **Silnik reguł (`Classifier`):** klasyfikacja operacji (wydatek, przychód, zwrot, oszczędności, pominięta, do decyzji) i wykrywanie par „płatność + zwrot” oraz „ta sama kwota w dwie strony” w oknie 10 dni.
- **Normalizacja kategorii:** uproszczony stemmer dla języka polskiego i ignorowanie kolejności słów, dzięki czemu różne zapisy tej samej kategorii łączą się automatycznie.
- **Paragony:** `VisionKit` (skaner dokumentów) i `Vision` (`VNRecognizeTextRequest`). Linie tekstu są składane z obserwacji według położenia, a parser wyciąga datę, sumę, pozycje i rabaty. Kategorie pozycji pochodzą z zapamiętanych reguł, słów kluczowych i domyślnej kategorii sklepu.
- **Dopasowanie paragonu do wyciągu:** po kwocie i dacie (do 3 dni różnicy), z wyborem najbliższej daty. Wynik to podział płatności na kategorie.
- **Nauka z Excela:** import historii z CSV, dopasowanie wpisów do operacji z wyciągu i wyuczenie reguł „sklep → kategoria”.

### Struktura projektu

| Plik | Zawartość |
|---|---|
| `BudzetApp.swift` | Punkt wejścia aplikacji |
| `Models.swift` | Modele danych, normalizacja nazw, narzędzia dat |
| `Importer.swift` | Parser CSV i wczytywanie wyciągu |
| `Classifier.swift` | Reguły klasyfikacji i wykrywanie par |
| `Store.swift`, `StoreExtras.swift` | Stan aplikacji, zapis, podsumowania, import Excela, eksport |
| `ReceiptParser.swift` | Rozpoznawanie tekstu (OCR) i parser paragonów |
| `ReceiptsView.swift` | Skanowanie i weryfikacja paragonów |
| `Views.swift`, `MoreViews.swift` | Ekrany aplikacji |

## Uruchomienie

Wymagania: Mac z Xcode, iPhone z iOS 17 lub nowszym (aparat działa tylko na prawdziwym urządzeniu).

1. Utwórz w Xcode nowy projekt *iOS > App* (SwiftUI) i usuń wygenerowane `BudzetApp.swift` oraz `ContentView.swift`.
2. Dodaj do projektu pliki `.swift` z tego repozytorium.
3. W ustawieniach celu (*Info*) dodaj klucz **Privacy - Camera Usage Description**, np. „Skanowanie paragonów”.
4. Uruchom na iPhonie. Przy darmowym koncie deweloperskim aplikacja działa 7 dni, potem trzeba ją uruchomić z Xcode ponownie.

### Format wyciągu

Aplikacja czyta CSV z nagłówkami: `Data operacji`, `Typ transakcji`, `Kwota` (opcjonalnie `Data waluty`, `Nazwa nadawcy`, `Nazwa odbiorcy`, `Opis transakcji`). Wyciąg w formacie `.xls` trzeba najpierw zapisać jako CSV.

## Prywatność

- Dane (operacje, paragony, reguły) są przechowywane lokalnie w pliku JSON na urządzeniu.
- Rozpoznawanie tekstu z paragonów odbywa się na urządzeniu, bez wysyłania zdjęć.
- Do repozytorium **nie należy dodawać** własnych wyciągów, plików Excel/CSV z danymi ani pliku `budzet.json` (są wykluczone w `.gitignore`).

## Ograniczenia i plan rozwoju

- Wyciąg wczytywany jest z pliku CSV. Automatyczne pobieranie transakcji z banku wymagałoby zewnętrznej usługi.
- Parser paragonów opiera się na regułach i został sprawdzony na ograniczonej liczbie paragonów. Każdy odczyt jest przed zapisem do poprawienia.
- Brak testów automatycznych i synchronizacji z iCloud.
- Pomysły na dalszy rozwój: Face ID, kopia zapasowa w iCloud, widżet „Dodaj paragon”, przypomnienia o paragonach, testy jednostkowe klasyfikatora i parsera.

## Technologie

Swift · SwiftUI · Swift Charts · Vision · VisionKit · PhotosUI · Foundation (`Codable`, `NSRegularExpression`)
