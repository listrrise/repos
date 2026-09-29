#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#include <dlfcn.h>

// Виджеты домашнего экрана в стиле iOS 16 для iOS 12 (SpringBoard).
// Настройки общие с dinapenis: /var/mobile/Library/Preferences/com.listrrise.dinapenis.plist

static NSString *const kWPrefsPath = @"/var/mobile/Library/Preferences/com.listrrise.dinapenis.plist";
static NSString *const kWPrefsChanged = @"com.listrrise.dinapenis/prefs.changed";

static BOOL WEnabled = YES;
static BOOL WClock = YES;
static BOOL WBattery = YES;
static BOOL WMusic = YES;

static void WLoadPrefs(void) {
	NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kWPrefsPath];
	if (!p) return;
	if (p[@"WidgetsEnabled"]) WEnabled = [p[@"WidgetsEnabled"] boolValue];
	if (p[@"WidgetClock"])     WClock   = [p[@"WidgetClock"] boolValue];
	if (p[@"WidgetBattery"])   WBattery = [p[@"WidgetBattery"] boolValue];
	if (p[@"WidgetMusic"])     WMusic   = [p[@"WidgetMusic"] boolValue];
}

static void WPrefsCallback(CFNotificationCenterRef center, void *observer,
	CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	WLoadPrefs();
	[[NSNotificationCenter defaultCenter] postNotificationName:@"DinaWidgetsPrefsChanged" object:nil];
}

// Пауза/плей через приватный MediaRemote (dlopen — собирается публичным SDK)
static void WSendMediaCommand(NSInteger cmd) {
	static void *handle = NULL;
	static int (*fn)(NSInteger, id) = NULL;
	static BOOL tried = NO;
	if (!tried) {
		tried = YES;
		handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
		if (handle) fn = (int (*)(NSInteger, id))dlsym(handle, "MRMediaRemoteSendCommand");
	}
	if (fn) fn(cmd, nil);
}

// ================= Окно (прозрачное для тапов мимо карточек) =================
@interface DWWidgetWindow : UIWindow
@end

@implementation DWWidgetWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	UIView *hit = [super hitTest:point withEvent:event];
	if (hit == self) return nil; // мимо карточек — тап уходит иконкам
	return hit;
}

@end

// ================= Карточка =================
static UIVisualEffectView *DWMakeCard(CGFloat height) {
	UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
	UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
	card.layer.cornerRadius = 22.0;
	card.layer.masksToBounds = YES;
	card.userInteractionEnabled = YES;
	[card.heightAnchor constraintEqualToConstant:height].active = YES;
	return card;
}

// ================= Менеджер =================
@interface DWManager : NSObject
@property (nonatomic, strong) DWWidgetWindow *window;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *clockTime;
@property (nonatomic, strong) UILabel *clockDate;
@property (nonatomic, strong) UILabel *batteryLabel;
@property (nonatomic, strong) UILabel *musicTitle;
@property (nonatomic, strong) UILabel *musicArtist;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL onHome;
+ (instancetype)shared;
- (void)install;
- (void)setOnHome:(BOOL)onHome;
@end

@implementation DWManager

+ (instancetype)shared {
	static DWManager *s = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[self alloc] init]; });
	return s;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rebuild)
			name:@"DinaWidgetsPrefsChanged" object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryChanged)
			name:UIDeviceBatteryLevelDidChangeNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryChanged)
			name:UIDeviceBatteryStateDidChangeNotification object:nil];
		[UIDevice currentDevice].batteryMonitoringEnabled = YES;
	}
	return self;
}

- (void)install {
	CGRect screen = [UIScreen mainScreen].bounds;
	_window = [[DWWidgetWindow alloc] initWithFrame:screen];
	_window.windowLevel = UIWindowLevelNormal + 50; // над иконками, под статус-баром и островом
	_window.backgroundColor = [UIColor clearColor];
	_window.hidden = YES;

	_stack = [[UIStackView alloc] init];
	_stack.axis = UILayoutConstraintAxisVertical;
	_stack.spacing = 12.0;
	_stack.userInteractionEnabled = NO; // тапы ловят только карточки
	CGFloat w = screen.size.width;
	_stack.frame = CGRectMake(16, 64, w - 32, 400);
	_stack.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[_window addSubview:_stack];

	[self rebuild];
	_timer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self
		selector:@selector(tick) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
	[self tick];
}

- (void)setOnHome:(BOOL)onHome {
	_onHome = onHome;
	[self applyVisibility];
}

- (void)applyVisibility {
	_window.hidden = !(WEnabled && _onHome);
}

- (void)rebuild {
	for (UIView *v in _stack.arrangedSubviews) {
		[_stack removeArrangedSubview:v];
		[v removeFromSuperview];
	}
	if (WClock)   [_stack addArrangedSubview:[self makeClockCard]];
	if (WBattery) [_stack addArrangedSubview:[self makeBatteryCard]];
	if (WMusic)   [_stack addArrangedSubview:[self makeMusicCard]];
	[self tick];
	[self applyVisibility];
}

// ---------- карточки ----------
- (UIVisualEffectView *)makeClockCard {
	UIVisualEffectView *card = DWMakeCard(96);
	_clockTime = [[UILabel alloc] initWithFrame:CGRectMake(20, 10, 300, 44)];
	_clockTime.font = [UIFont systemFontOfSize:36 weight:UIFontWeightSemibold];
	_clockTime.textColor = [UIColor whiteColor];
	[card.contentView addSubview:_clockTime];
	_clockDate = [[UILabel alloc] initWithFrame:CGRectMake(20, 56, 300, 22)];
	_clockDate.font = [UIFont systemFontOfSize:15.0];
	_clockDate.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
	[card.contentView addSubview:_clockDate];
	return card;
}

- (UIVisualEffectView *)makeBatteryCard {
	UIVisualEffectView *card = DWMakeCard(60);
	_batteryLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, 300, 60)];
	_batteryLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
	_batteryLabel.textColor = [UIColor whiteColor];
	[card.contentView addSubview:_batteryLabel];
	return card;
}

- (UIVisualEffectView *)makeMusicCard {
	UIVisualEffectView *card = DWMakeCard(84);
	_musicTitle = [[UILabel alloc] initWithFrame:CGRectMake(20, 12, 300, 24)];
	_musicTitle.font = [UIFont boldSystemFontOfSize:16.0];
	_musicTitle.textColor = [UIColor whiteColor];
	[card.contentView addSubview:_musicTitle];
	_musicArtist = [[UILabel alloc] initWithFrame:CGRectMake(20, 38, 300, 20)];
	_musicArtist.font = [UIFont systemFontOfSize:13.0];
	_musicArtist.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
	[card.contentView addSubview:_musicArtist];
	UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 58, 300, 16)];
	hint.font = [UIFont systemFontOfSize:11.0];
	hint.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
	hint.text = @"тап — пауза / играть";
	[card.contentView addSubview:hint];
	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(musicTap)];
	[card addGestureRecognizer:tap];
	return card;
}

// ---------- обновления ----------
- (void)tick {
	NSDate *now = [NSDate date];
	static NSDateFormatter *tf = nil, *df = nil;
	if (!tf) {
		tf = [[NSDateFormatter alloc] init];
		tf.dateFormat = @"HH:mm";
		df = [[NSDateFormatter alloc] init];
		df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"ru_RU"];
		df.dateFormat = @"EEEE, d MMMM";
	}
	if (_clockTime) _clockTime.text = [tf stringFromDate:now];
	if (_clockDate) _clockDate.text = [df stringFromDate:now];

	NSDictionary *info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
	if (_musicTitle) {
		_musicTitle.text = info[MPMediaItemPropertyTitle] ?: @"Ничего не играет";
		_musicArtist.text = info[MPMediaItemPropertyArtist] ?: @"—";
	}
	[self batteryChanged];
}

- (void)batteryChanged {
	if (!_batteryLabel) return;
	UIDevice *d = [UIDevice currentDevice];
	float level = d.batteryLevel; // -1 если неизвестно
	NSString *state = @"";
	if (d.batteryState == UIDeviceBatteryStateCharging) state = @" • заряжается";
	else if (d.batteryState == UIDeviceBatteryStateFull) state = @" • заряжен";
	if (level < 0) _batteryLabel.text = @"🔋 —";
	else _batteryLabel.text = [NSString stringWithFormat:@"🔋 %d%%%@", (int)(level * 100), state];
}

- (void)musicTap {
	WSendMediaCommand(2); // toggle play/pause
}

@end

// Видимость только на домашнем экране
%hook SBHomeScreenViewController
- (void)viewDidAppear:(BOOL)animated {
	%orig;
	[[DWManager shared] setOnHome:YES];
}
- (void)viewDidDisappear:(BOOL)animated {
	%orig;
	[[DWManager shared] setOnHome:NO];
}
%end

%ctor {
	WLoadPrefs();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		WPrefsCallback, CFSTR("com.listrrise.dinapenis/prefs.changed"),
		NULL, CFNotificationSuspensionBehaviorCoalesce);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{
			[[DWManager shared] install];
		});
}
