# File Transfer (R8/W8)

The R8 and W8 utilities transfer files between the host and CP/M.

## R8 - Read from Host

Copies a file from the app's Imports folder into CP/M.

### Usage
```
R8 filename.ext
```

### Example
```
A>R8 MYFILE.TXT
```

This copies `MYFILE.TXT` from the Imports folder to the current CP/M drive. Run
`R8` with no name to read the first file in the folder.

## W8 - Write to Host

Copies a file from CP/M to the app's Exports folder.

### Usage
```
W8 filename.ext
```

### Example
```
A>W8 OUTPUT.TXT
```

This copies `OUTPUT.TXT` from the current CP/M drive to the Exports folder.

## Folder Locations

R8 always reads from the app's **Imports** folder and W8 always writes to its
**Exports** folder — there is no per-transfer Save/Open dialog.

### iOS / iPadOS
The app's Documents folder is published to the Files app:

- **Imports**: Files → On My iPhone/iPad → **Z80CPM** → Imports
- **Exports**: Files → On My iPhone/iPad → **Z80CPM** → Exports

### macOS (Catalyst)
The app is sandboxed, so the folders live inside its container:

- **Imports**: ~/Library/Containers/com.awohl.cpm/Data/Documents/Imports
- **Exports**: ~/Library/Containers/com.awohl.cpm/Data/Documents/Exports

Use the **Open Imports Folder** and **Open Exports Folder** menu items for quick
access (on macOS the container path is hidden in Finder, so use the menu).

## Import File… — bring in a file from anywhere

R8 only reads the Imports folder. To use a file that lives somewhere else, choose
**Import File… (for R8)** from the menu: it opens the system file picker, copies
the file(s) you select into Imports, and then you run `R8 name` to read one into
CP/M.

## Tips

- Filenames must follow CP/M conventions (8.3 format)
- Files are transferred as binary (no conversion)
- The Combo disk includes R8.COM and W8.COM on drive B:
