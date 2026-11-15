// 캐릭터 창을 모든 데스크탑(Spaces)에 보이게 하는 작은 GDExtension.
// Godot 는 창의 collectionBehavior 를 바꾸는 설정이 없어서, 이 라이브러리가 Godot 안에 올라와
// 1초마다 이 앱의 창들에 canJoinAllSpaces 를 붙인다(창이 새로 생기거나 Godot 가 되돌려도 다시 붙는다).
// Godot API 는 하나도 안 쓴다: 진입 함수는 빈 초기화 구조체만 채워 돌려준다.
#import <Cocoa/Cocoa.h>
#include <stdint.h>

typedef struct {
    int minimum_initialization_level;
    void *userdata;
    void (*initialize)(void *userdata, int level);
    void (*deinitialize)(void *userdata, int level);
} Init;

static void noop(void *u, int l) {}
static BOOL started = NO;

static void apply(void) {
    for (NSWindow *w in NSApp.windows) {
        NSWindowCollectionBehavior want = NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
        if ((w.collectionBehavior & want) != want) {
            w.collectionBehavior = (w.collectionBehavior
                & ~(NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorManaged)) | want;
            // 확인용: 바꾼 내용을 임시 폴더 rhhg_spaces.txt 에 남긴다.
            NSString *line = [NSString stringWithFormat:@"%@ 0x%lx level %ld\n", w.title, (unsigned long)w.collectionBehavior, (long)w.level];
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rhhg_spaces.txt"];
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

static void start(void) {
    if (started) return;
    started = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        apply();
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { apply(); }];
    });
}

__attribute__((visibility("default")))
uint8_t rhhg_spaces_init(void *get_proc_address, void *library, Init *r_init) {
    r_init->minimum_initialization_level = 0;
    r_init->userdata = NULL;
    r_init->initialize = noop;
    r_init->deinitialize = noop;
    start();
    return 1;
}
