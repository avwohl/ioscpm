//
//  EmulatorProfileTests.swift
//
//  Saving a machine under a name, and getting the same machine back.
//
//  `todo.txt` carried "no configuration profiles - named sets of ROM, disks,
//  boot string, terminal and key map. KeyProfile (KeyMap.swift) is only the
//  key-map half." EmulatorProfile is the other half. Applying one touches the
//  emulator and the view model and cannot be driven here; everything that
//  decides WHAT gets applied is a value, and that is what this checks.
//
//  The cases worth having are the ones where a profile comes back from
//  somewhere it was not written: an older version of the app, a defaults plist
//  somebody edited, a store with two profiles of the same name in it. Each of
//  those reaches the apply loop, and the apply loop indexes four disk slots.
//
//  Run with Tests/run_tests.sh.
//

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(label)")
}

func section(_ title: String) {
    print("\n\(title)")
    print(String(repeating: "-", count: 60))
}

func section(_ title: String, _ body: () -> Void) {
    section(title)
    body()
}

func sampleProfile(_ name: String = "CP/M 2.2") -> EmulatorProfile {
    EmulatorProfile(
        name: name,
        romFilename: "emu_avw.rom",
        diskFilenames: ["hd1k_combo.img", "hd1k_infocom.img", "", ""],
        bootString: "C",
        keyProfileName: "Custom",
        keyBindings: ["up": "^E", "down": "^X", "f1": "\\E1"],
        scrollbackCapacity: 2000,
        bellEnabled: false,
        warnManifestWrites: false,
        showKeyRow: false,
        newDiskSizeBytes: DiskSize.offered[1].bytes)
}

func runAllTests() {

    section("A profile round-trips through JSON unchanged") {
        let p = sampleProfile()
        guard let data = try? JSONEncoder().encode(p),
              let back = try? JSONDecoder().decode(EmulatorProfile.self, from: data) else {
            check(false, "a profile encodes and decodes"); return
        }
        check(back == p, "every field survives the round trip")
        check(back.keyBindings["up"] == "^E", "including a custom key binding")
        check(back.diskFilenames == p.diskFilenames, "and the four disk slots in order")
        check(back.bellEnabled == false, "and a setting whose value is the non-default one")
    }

    section("A profile always has four disk slots") {
        // The apply loop indexes these. A short array from an older version, or
        // a long one from a hand-edited plist, must not reach it.
        check(EmulatorProfile(name: "x", diskFilenames: []).diskFilenames.count == 4,
              "an empty slot list is padded to four")
        check(EmulatorProfile(name: "x", diskFilenames: ["a"]).diskFilenames == ["a", "", "", ""],
              "a short one is padded on the right, so slot 0 stays slot 0")
        check(EmulatorProfile(name: "x", diskFilenames: ["a", "b", "c", "d", "e"]).diskFilenames.count == 4,
              "and a long one is truncated")

        let json = Data(#"{"name":"old","diskFilenames":["a","b"]}"#.utf8)
        guard let old = try? JSONDecoder().decode(EmulatorProfile.self, from: json) else {
            check(false, "a profile from an older version decodes"); return
        }
        check(old.diskFilenames.count == 4, "a decoded profile is padded too, not only a constructed one")
        check(old.romFilename == "", "a missing field takes its default")
        check(old.scrollbackCapacity == 1000, "including the ones with a non-empty default")
        check(old.bellEnabled, "and the bell defaults to on, as it does everywhere else")
    }

    section("Values that would be applied verbatim are clamped first") {
        check(EmulatorProfile(name: "x", scrollbackCapacity: -1).scrollbackCapacity == 0,
              "a negative scrollback is clamped to 0")
        check(EmulatorProfile(name: "x", scrollbackCapacity: 1 << 30).scrollbackCapacity
                == TerminalScreen.maxScrollbackCapacity,
              "and a runaway one to the cap the terminal uses")
        check(EmulatorProfile(name: "x", newDiskSizeBytes: 16 * 1024 * 1024).newDiskSizeBytes
                == DiskSize.default.bytes,
              "a disk size the picker no longer offers falls back to the default")
        check(EmulatorProfile(name: "x", newDiskSizeBytes: DiskSize.offered[1].bytes).newDiskSizeBytes
                == DiskSize.offered[1].bytes,
              "and one it does offer is kept")
    }

    section("Names") {
        check(EmulatorProfile(name: "  Spaced  ").name == "Spaced", "surrounding space is trimmed")
        check(EmulatorProfile(name: "").name == "Untitled", "an empty name becomes Untitled")
        check(EmulatorProfile(name: "   ").name == "Untitled", "and so does one that is only space")
        let long = String(repeating: "A", count: 200)
        check(EmulatorProfile(name: long).name.count == EmulatorProfile.maxNameLength,
              "a name too long for the picker is cut to length")
    }

    section("The store: saving, replacing and deleting") {
        var store = ProfileStore()
        check(store.profiles.isEmpty, "a new store is empty")
        check(store.lastUsed == nil, "with nothing last used")

        store.save(sampleProfile("Games"))
        store.save(sampleProfile("Work"))
        check(store.profiles.count == 2, "two profiles are two profiles")
        check(store.names == ["Games", "Work"], "and they are listed alphabetically")

        store.save(sampleProfile("Aardvark"))
        check(store.names == ["Aardvark", "Games", "Work"], "a new one sorts into place")

        var updated = sampleProfile("Games")
        updated.bootString = "2"
        store.save(updated)
        check(store.profiles.count == 3, "saving over an existing name replaces rather than duplicates")
        check(store.profile(named: "Games")?.bootString == "2", "with the new value")

        store.delete(named: "Games")
        check(store.names == ["Aardvark", "Work"], "delete removes exactly one")
        store.delete(named: "Nothing Here")
        check(store.names == ["Aardvark", "Work"], "and deleting what is not there changes nothing")
    }

    section("The store: the last-used pointer") {
        var store = ProfileStore()
        store.save(sampleProfile("Games"))
        store.markUsed("Games")
        check(store.lastUsedName == "Games", "applying a profile records it")
        check(store.lastUsed?.name == "Games", "and it can be looked up")

        store.markUsed("Not A Profile")
        check(store.lastUsedName == nil, "marking one that does not exist clears the pointer")

        store.markUsed("Games")
        store.delete(named: "Games")
        check(store.lastUsedName == nil, "deleting the current profile clears the pointer")
        check(store.lastUsed == nil, "so nothing dangles")
    }

    section("The store: renaming") {
        var store = ProfileStore()
        store.save(sampleProfile("Games"))
        store.save(sampleProfile("Work"))
        store.markUsed("Games")

        check(store.rename("Games", to: "Infocom") == "Infocom", "a rename reports the new name")
        check(store.names == ["Infocom", "Work"], "the list is renamed and re-sorted")
        check(store.lastUsedName == "Infocom", "and the last-used pointer follows it")

        check(store.rename("Infocom", to: "Work") == nil, "renaming onto a name in use is refused")
        check(store.names == ["Infocom", "Work"], "and changes nothing")
        check(store.rename("Nothing Here", to: "Anything") == nil, "renaming what does not exist is refused")
        check(store.rename("Infocom", to: "  Infocom  ") == "Infocom",
              "renaming to the same name after trimming is a no-op, not a clash with itself")
        check(store.rename("Infocom", to: "") == "Untitled", "and an empty new name becomes Untitled")
    }

    section("The store: names that are already taken") {
        var store = ProfileStore()
        check(store.uniqueName(basedOn: "Games") == "Games", "an unused name is used as it is")
        store.save(sampleProfile("Games"))
        check(store.uniqueName(basedOn: "Games") == "Games 2", "a taken one gets a number")
        store.save(sampleProfile("Games 2"))
        check(store.uniqueName(basedOn: "Games") == "Games 3", "and the next number after that")

        let long = String(repeating: "A", count: EmulatorProfile.maxNameLength)
        store.save(sampleProfile(long))
        let next = store.uniqueName(basedOn: long)
        check(next != EmulatorProfile.sanitized(name: long),
              "a name already at the length limit still gets a distinct one")
        check(next.count <= EmulatorProfile.maxNameLength, "and it still fits")
    }

    section("The store: bytes in, bytes out") {
        var store = ProfileStore()
        store.save(sampleProfile("Games"))
        store.save(sampleProfile("Work"))
        store.markUsed("Work")
        guard let data = store.encoded() else { check(false, "a store encodes"); return }
        let back = ProfileStore.decoded(from: data)
        check(back == store, "a store round-trips through its own bytes")
        check(back.lastUsedName == "Work", "including which profile was last used")

        check(ProfileStore.decoded(from: nil).profiles.isEmpty, "no stored data is an empty store")
        check(ProfileStore.decoded(from: Data("not json".utf8)).profiles.isEmpty,
              "and unreadable data is an empty store, not a crash")
        check(ProfileStore.decoded(from: Data()).profiles.isEmpty, "and so are zero bytes")

        // A store hand-edited into having two profiles with one name: the
        // picker cannot address the second, so it is dropped rather than shown.
        let dupes = Data(#"{"profiles":[{"name":"A","romFilename":"r1","diskFilenames":[],"bootString":"","keyProfileName":"WordStar","keyBindings":{},"scrollbackCapacity":1000,"bellEnabled":true,"warnManifestWrites":true,"showKeyRow":true,"newDiskSizeBytes":8388608},{"name":"A","romFilename":"r2","diskFilenames":[],"bootString":"","keyProfileName":"WordStar","keyBindings":{},"scrollbackCapacity":1000,"bellEnabled":true,"warnManifestWrites":true,"showKeyRow":true,"newDiskSizeBytes":8388608}]}"#.utf8)
        let deduped = ProfileStore.decoded(from: dupes)
        check(deduped.profiles.count == 1, "two profiles with the same name become one")
        check(deduped.profiles.first?.romFilename == "r1", "and it is the first of them")

        // A last-used pointer at a profile that is not in the store.
        let dangling = ProfileStore(profiles: [sampleProfile("Games")], lastUsedName: "Gone")
        check(dangling.lastUsedName == nil, "a last-used pointer at a missing profile is dropped")
    }

    section("The one-line summary that tells two profiles apart") {
        let p = sampleProfile()
        check(p.summary.contains("2 disks"), "the summary counts the disks that are set")
        check(p.summary.contains("boot C"), "and says what it boots")
        check(p.summary.contains("Custom"), "and which key map is in force")
        check(p.summary.contains("bell off"), "and says so when the bell is off")

        let quiet = EmulatorProfile(name: "Bare")
        check(quiet.summary.contains("0 disks"), "an empty profile says it has no disks")
        check(!quiet.summary.contains("boot"), "and says nothing about a boot string it does not have")
        check(!quiet.summary.contains("bell"), "nor about a bell that is simply on")

        let one = EmulatorProfile(name: "One", diskFilenames: ["a.img"])
        check(one.summary.contains("1 disk") && !one.summary.contains("1 disks"),
              "one disk is one disk, not one disks")
    }
}

@main
enum EmulatorProfileTestMain {
    static func main() {
        runAllTests()
        print("\n" + String(repeating: "=", count: 60))
        print("Results: \(checks - failures) passed, \(failures) failed")
        if failures > 0 {
            print("Some tests failed")
            exit(1)
        }
        print("All tests passed")
        exit(0)
    }
}
