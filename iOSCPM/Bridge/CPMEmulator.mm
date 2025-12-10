/*
 * CPMEmulator.mm - Objective-C++ implementation of CP/M emulator bridge
 */

#import "CPMEmulator.h"
#include "qkz80.h"
#include "qkz80_mem.h"
#include "CPMBios.h"
#include <queue>
#include <vector>
#include <cstring>

// Memory class with write protection for BIOS area
class iOSCPMMem : public qkz80_cpu_mem {
    uint16_t protect_start = 0;
    uint16_t protect_end = 0;
    bool protection_enabled = false;

public:
    void set_write_protection(uint16_t start, uint16_t end) {
        protect_start = start;
        protect_end = end;
        protection_enabled = true;
    }

    void disable_write_protection() {
        protection_enabled = false;
    }

    void store_mem(qkz80_uint16 addr, qkz80_uint8 abyte) override {
        if (protection_enabled && addr >= protect_start && addr < protect_end) {
            // Silently ignore writes to protected memory
            return;
        }
        qkz80_cpu_mem::store_mem(addr, abyte);
    }
};

@implementation CPMEmulator {
    iOSCPMMem *_memory;
    qkz80 *_cpu;
    std::queue<int> _inputQueue;
    std::vector<uint8_t> _diskA;
    std::vector<uint8_t> _diskB;
    std::vector<uint8_t> _cpmSystem;  // Copy for warm boot

    int _currentDisk;
    int _currentTrack;
    int _currentSector;
    uint16_t _dmaAddr;

    BOOL _running;
    BOOL _waitingForInput;

    dispatch_queue_t _emulatorQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memory = new iOSCPMMem();
        _cpu = new qkz80(_memory);
        _currentDisk = 0;
        _currentTrack = 0;
        _currentSector = 1;
        _dmaAddr = 0x0080;
        _running = NO;
        _waitingForInput = NO;

        _emulatorQueue = dispatch_queue_create("com.cpmemu.emulator", DISPATCH_QUEUE_SERIAL);

        // Initialize BIOS tables
        cpm_init_bios(_cpu->get_mem());
    }
    return self;
}

- (void)dealloc {
    [self stop];
    delete _cpu;
    delete _memory;
}

- (BOOL)isRunning {
    return _running;
}

#pragma mark - System Loading

- (BOOL)loadSystemFromData:(NSData *)data {
    if (data.length > 0x2000) return NO;  // Max 8KB for CCP+BDOS

    char *mem = _cpu->get_mem();
    memcpy(&mem[CPM_LOAD_ADDR], data.bytes, data.length);

    // Save copy for warm boot
    _cpmSystem.assign((const uint8_t *)data.bytes,
                      (const uint8_t *)data.bytes + data.length);

    [self notifyStatus:@"System loaded"];
    return YES;
}

- (BOOL)loadDiskA:(NSData *)data {
    _diskA.assign((const uint8_t *)data.bytes,
                  (const uint8_t *)data.bytes + data.length);

    if (_diskA.size() < CPM_DISK_SIZE) {
        _diskA.resize(CPM_DISK_SIZE, 0xE5);
    }

    [self notifyStatus:@"Disk A loaded"];
    return YES;
}

- (BOOL)loadDiskB:(NSData *)data {
    _diskB.assign((const uint8_t *)data.bytes,
                  (const uint8_t *)data.bytes + data.length);

    if (_diskB.size() < CPM_DISK_SIZE) {
        _diskB.resize(CPM_DISK_SIZE, 0xE5);
    }

    [self notifyStatus:@"Disk B loaded"];
    return YES;
}

#pragma mark - Emulation Control

- (void)start {
    if (_running) return;

    _cpu->set_cpu_mode(qkz80::MODE_8080);
    _cpu->regs.AF.set_pair16(0);
    _cpu->regs.BC.set_pair16(0);
    _cpu->regs.DE.set_pair16(0);
    _cpu->regs.HL.set_pair16(0);
    _cpu->regs.PC.set_pair16(BIOS_BASE);  // Start at BIOS BOOT
    _cpu->regs.SP.set_pair16(CPM_LOAD_ADDR);

    // Enable write protection on BIOS tables
    _memory->set_write_protection(BIOS_BASE, DPH0_ADDR);

    _running = YES;
    _waitingForInput = NO;

    [self notifyStatus:@"Starting CP/M..."];

    // Start emulation loop on background queue
    dispatch_async(_emulatorQueue, ^{
        [self runLoop];
    });
}

- (void)stop {
    _running = NO;
}

- (void)reset {
    [self stop];

    // Wait for emulator to stop
    dispatch_sync(_emulatorQueue, ^{});

    // Clear input queue
    while (!_inputQueue.empty()) _inputQueue.pop();

    _currentDisk = 0;
    _currentTrack = 0;
    _currentSector = 1;
    _dmaAddr = 0x0080;
    _waitingForInput = NO;

    // Reinitialize BIOS
    cpm_init_bios(_cpu->get_mem());

    // Reload system if available
    if (!_cpmSystem.empty()) {
        char *mem = _cpu->get_mem();
        memcpy(&mem[CPM_LOAD_ADDR], _cpmSystem.data(), _cpmSystem.size());
    }
}

#pragma mark - Console I/O

- (void)sendKey:(unichar)character {
    int ch = (int)character;
    if (ch == '\n') ch = '\r';  // Convert newline to CR for CP/M

    _inputQueue.push(ch);
    _waitingForInput = NO;
}

- (void)sendString:(NSString *)string {
    for (NSUInteger i = 0; i < string.length; i++) {
        [self sendKey:[string characterAtIndex:i]];
    }
}

#pragma mark - Disk Management

- (NSData *)getDiskAData {
    if (_diskA.empty()) return nil;
    return [NSData dataWithBytes:_diskA.data() length:_diskA.size()];
}

- (NSData *)getDiskBData {
    if (_diskB.empty()) return nil;
    return [NSData dataWithBytes:_diskB.data() length:_diskB.size()];
}

- (void)createEmptyDiskA {
    _diskA.assign(CPM_DISK_SIZE, 0xE5);
    [self notifyStatus:@"Created empty Disk A"];
}

- (void)createEmptyDiskB {
    _diskB.assign(CPM_DISK_SIZE, 0xE5);
    [self notifyStatus:@"Created empty Disk B"];
}

#pragma mark - CPU State

- (uint16_t)programCounter {
    return _cpu->regs.PC.get_pair16();
}

- (uint16_t)stackPointer {
    return _cpu->regs.SP.get_pair16();
}

#pragma mark - Private Methods

- (void)runLoop {
    while (_running) {
        if (_waitingForInput) {
            // Wait a bit before checking again
            [NSThread sleepForTimeInterval:0.01];
            continue;
        }

        // Run a batch of instructions
        for (int i = 0; i < 10000 && _running && !_waitingForInput; i++) {
            uint16_t pc = _cpu->regs.PC.get_pair16();

            if (cpm_is_bios_trap(pc)) {
                [self handleBios:pc];
                continue;
            }

            _cpu->execute();
        }

        // Small yield to prevent CPU spinning
        [NSThread sleepForTimeInterval:0.001];
    }
}

- (void)handleBios:(uint16_t)pc {
    int offset = pc - BIOS_BASE;
    char *mem = _cpu->get_mem();

    // Helper to simulate RET instruction
    auto do_ret = [&]() {
        uint16_t sp = _cpu->regs.SP.get_pair16();
        uint16_t ret_addr = (uint8_t)mem[sp] | ((uint8_t)mem[sp+1] << 8);
        _cpu->regs.SP.set_pair16(sp + 2);
        _cpu->regs.PC.set_pair16(ret_addr);
    };

    switch (offset) {
        case BIOS_BOOT: {
            // Cold boot - initialize page zero
            mem[0x0000] = 0xC3;  // JMP WBOOT
            mem[0x0001] = static_cast<char>((BIOS_BASE + BIOS_WBOOT) & 0xFF);
            mem[0x0002] = static_cast<char>((BIOS_BASE + BIOS_WBOOT) >> 8);
            mem[0x0003] = 0x00;  // IOBYTE
            mem[0x0004] = 0x00;  // Current drive/user
            mem[0x0005] = 0xC3;  // JMP BDOS
            mem[0x0006] = 0x06;  // BDOS entry at E806
            mem[0x0007] = 0xE8;

            _currentDisk = 0;
            _currentTrack = 0;
            _currentSector = 1;
            _dmaAddr = 0x0080;

            _cpu->regs.BC.set_pair16(0x0000);
            _cpu->regs.PC.set_pair16(CPM_LOAD_ADDR);  // Jump to CCP

            [self notifyStatus:@"CP/M Cold Boot"];
            break;
        }

        case BIOS_WBOOT: {
            // Warm boot - reload CCP+BDOS
            if (!_cpmSystem.empty()) {
                memcpy(&mem[CPM_LOAD_ADDR], _cpmSystem.data(), _cpmSystem.size());
            }

            mem[0x0000] = 0xC3;
            mem[0x0001] = static_cast<char>((BIOS_BASE + BIOS_WBOOT) & 0xFF);
            mem[0x0002] = static_cast<char>((BIOS_BASE + BIOS_WBOOT) >> 8);
            mem[0x0005] = 0xC3;
            mem[0x0006] = 0x06;
            mem[0x0007] = static_cast<char>(0xE8);

            _dmaAddr = 0x0080;
            int drive = (uint8_t)mem[0x0004] & 0x0F;
            _currentDisk = drive;

            _cpu->regs.BC.set_pair16(drive);
            _cpu->regs.PC.set_pair16(CPM_LOAD_ADDR);
            break;
        }

        case BIOS_CONST: {
            // Console status
            _cpu->set_reg8(_inputQueue.empty() ? 0x00 : 0xFF, qkz80::reg_A);
            do_ret();
            break;
        }

        case BIOS_CONIN: {
            // Console input
            if (_inputQueue.empty()) {
                _waitingForInput = YES;
                if ([_delegate respondsToSelector:@selector(emulatorDidRequestInput)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate emulatorDidRequestInput];
                    });
                }
                return;  // Will retry when input available
            }
            int ch = _inputQueue.front();
            _inputQueue.pop();
            _cpu->set_reg8(ch & 0x7F, qkz80::reg_A);
            do_ret();
            break;
        }

        case BIOS_CONOUT: {
            // Console output
            int ch = _cpu->get_reg8(qkz80::reg_C) & 0x7F;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate emulatorDidOutputCharacter:(unichar)ch];
            });
            do_ret();
            break;
        }

        case BIOS_LIST:
        case BIOS_PUNCH:
            do_ret();
            break;

        case BIOS_READER:
            _cpu->set_reg8(0x1A, qkz80::reg_A);  // EOF
            do_ret();
            break;

        case BIOS_HOME:
            _currentTrack = 0;
            do_ret();
            break;

        case BIOS_SELDSK: {
            int disk = _cpu->get_reg8(qkz80::reg_C);
            uint16_t dph = 0;

            static const uint16_t dph_table[4] = {
                DPH0_ADDR, DPH1_ADDR, DPH2_ADDR, DPH3_ADDR
            };

            if (disk < 4) {
                dph = dph_table[disk];
                _currentDisk = disk;
            }

            _cpu->regs.HL.set_pair16(dph);
            do_ret();
            break;
        }

        case BIOS_SETTRK:
            _currentTrack = _cpu->regs.BC.get_pair16();
            do_ret();
            break;

        case BIOS_SETSEC:
            _currentSector = _cpu->regs.BC.get_pair16();
            do_ret();
            break;

        case BIOS_SETDMA:
            _dmaAddr = _cpu->regs.BC.get_pair16();
            do_ret();
            break;

        case BIOS_READ:
            _cpu->set_reg8([self diskRead], qkz80::reg_A);
            do_ret();
            break;

        case BIOS_WRITE:
            _cpu->set_reg8([self diskWrite], qkz80::reg_A);
            do_ret();
            break;

        case BIOS_PRSTAT:
            _cpu->set_reg8(0xFF, qkz80::reg_A);  // Printer ready
            do_ret();
            break;

        case BIOS_SECTRN: {
            // Sector translation
            uint16_t logical = _cpu->regs.BC.get_pair16();
            uint16_t xlt = _cpu->regs.DE.get_pair16();
            uint16_t physical;

            if (xlt == 0) {
                physical = logical + 1;  // No translation
            } else {
                physical = (uint8_t)mem[xlt + logical];
            }
            _cpu->regs.HL.set_pair16(physical);
            do_ret();
            break;
        }

        default:
            // Unknown BIOS call
            do_ret();
            break;
    }
}

- (int)diskRead {
    std::vector<uint8_t> *disk = [self currentDisk];
    if (!disk || disk->empty()) return 1;

    int logical_sector = _currentSector - 1;
    int offset = _currentTrack * CPM_TRACK_SIZE + logical_sector * CPM_SECTOR_SIZE;

    if (offset < 0 || offset + CPM_SECTOR_SIZE > (int)disk->size()) return 1;

    char *mem = _cpu->get_mem();
    memcpy(&mem[_dmaAddr], &(*disk)[offset], CPM_SECTOR_SIZE);
    return 0;
}

- (int)diskWrite {
    std::vector<uint8_t> *disk = [self currentDisk];
    if (!disk || disk->empty()) return 1;

    int logical_sector = _currentSector - 1;
    int offset = _currentTrack * CPM_TRACK_SIZE + logical_sector * CPM_SECTOR_SIZE;

    if (offset < 0 || offset + CPM_SECTOR_SIZE > (int)disk->size()) return 1;

    char *mem = _cpu->get_mem();
    memcpy(&(*disk)[offset], &mem[_dmaAddr], CPM_SECTOR_SIZE);
    return 0;
}

- (std::vector<uint8_t> *)currentDisk {
    switch (_currentDisk) {
        case 0: return &_diskA;
        case 1: return &_diskB;
        default: return nullptr;
    }
}

- (void)notifyStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate emulatorDidChangeStatus:status];
    });
}

@end
