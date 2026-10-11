# Minimalia

Minimalia is a quiet computer for your Mac. Open it and the screen becomes a calm, full-screen prompt in the spirit of the machines of the 1980s, with the tools of today behind it: your files, a word processor that opens Word documents, the web without the noise, 75,000 free books, your films, and an assistant that runs on the Mac itself. There are no notifications, no feeds and no windows to juggle.

I built it for anyone who wants to focus, including me.

![The Minimalia prompt](docs/boot.jpg)

## Programs

Everything opens inside Minimalia and returns to the prompt with Esc.

| Type | Program | What it does |
|---|---|---|
| `FOLIO` | Minimalia Folio | Word processor with menus and a toolbar. Opens and saves .docx, .doc, .odt, .rtf and .txt, prints and exports PDF |
| `BROWSE` | Minimalia Browse | The real web, shown in greyscale, with ads, trackers and cookie banners blocked and nothing playing by itself. Any page can be turned into plain text |
| `SHELF` | Minimalia Shelf | Project Gutenberg's free library, organised into shelves, read a page at a time like an e-reader |
| `FILM` | Minimalia Film | The films on your Mac or an external drive, arranged like a quiet cinema and played in greyscale |
| `WRITE` | Write | One page a day, with the line you are writing held in the middle of the screen |
| `PAD` | Minimalia Pad | Formatted writing without leaving the prompt, keyboard only |
| `EDIT` | Minimalia Edit | Plain text editor |
| `AI` | Intelligence | Apple's on-device model. Nothing you type leaves the Mac |

![Minimalia Folio](docs/folio.jpg)

![Minimalia Shelf](docs/shelf.jpg)

![Reading in Minimalia Shelf](docs/reader.jpg)

## At the prompt

    HELP                    every command, in two columns
    HELP FOLIO              everything about one command or program
    DIR                     list the folder you are in
    CD Desktop              move into a folder (Tab completes names)
    DOCS                    every Word document you own, newest first
    FOLIO 3                 open document 3 from that list
    WEB 15-minute city      search Google
    NEWS CBC                today's headlines from a quiet news site
    SHELF neolithic         find free books on a subject
    FILM /Volumes/Films     also look for films on an external drive
    NOTE call the press     add a line to your notebook
    SUMMARIZE               a short summary of the last page or a file
    COLOR PAPER             CALM, PAPER, GREEN, AMBER, WHITE or BLUE
    EXIT                    back to your Mac

![Help](docs/help.jpg)

## Calm by design

- The default CALM scheme is soft charcoal and warm grey rather than pure black and white. Text contrast is about 10:1, well above the 4.5:1 accessibility minimum. PAPER is its daylight twin.
- Programs use greys only. Coloured text in a document is shown in grey but saved with its real colours.
- Text is set in Atkinson Hyperlegible Mono, designed by the Braille Institute for legibility.
- The cursor is steady, nothing moves by itself, and every screen keeps the same layout.
- DEL and RD move files to the Trash. Nothing is erased for good.

## Requirements

- macOS 26 or later on Apple silicon.
- The assistant needs Apple Intelligence turned on in System Settings.
- Film plays .mp4, .m4v and .mov files.

## Building

    ./build.sh

This compiles Sources/ into Minimalia.app and WordApp/ into Minimalia Folio.app, a standalone version of the word processor. It needs Xcode. To stop macOS asking for folder access after every build, sign with a stable certificate: build.sh uses a "Developer ID Application" or "Minimalia Developer" certificate when one is in your keychain.

## Credits

Text is set in Atkinson Hyperlegible Mono by the Braille Institute, under the SIL Open Font License (Resources/Fonts/OFL.txt). Books come from Project Gutenberg. The start-up chime is not included in this repository; add your own as Resources/Chime.mp3.

## Licence

Minimalia is free software under the GNU General Public License, version 3. See LICENSE.

Copyright 2026 Eric Vaz.
