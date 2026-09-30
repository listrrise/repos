#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CallKit/CallKit.h>
#include <dlfcn.h>
#include <notify.h>

// ================= Prefs =================
static NSString *const kDIPrefsPath = @"/var/mobile/Library/Preferences/com.listrise.dinapenis.plist";
static NSString *const kDIPrefsChanged = @"com.listrise.dinapenis/prefs.changed";

static BOOL DIEnabled = YES;
static BOOL DIShowMedia = YES;
static BOOL DIShowCalls = YES;
static BOOL DICompactIcons = YES; // компактный контент в свёрнутой пилюле
static BOOL DIHaptics = YES;
static CGFloat DITopOffset = 11.0;
static CGFloat DIAnimSpeed = 1.0; // 0.5..1.5, 1.0 = норма
static BOOL DISwipes = YES; // свайпы: влево — назад, вправо — вперёд
static BOOL DIShowCharging = YES;
static BOOL DIFake = NO; // фейк-активность для превью из настроек

static void DILoadPrefs(void) {
	NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kDIPrefsPath];
	if (!p) return;
	if (p[@"Enabled"])      DIEnabled      = [p[@"Enabled"] boolValue];
	if (p[@"ShowMedia"])    DIShowMedia    = [p[@"ShowMedia"] boolValue];
	if (p[@"ShowCalls"])    DIShowCalls    = [p[@"ShowCalls"] boolValue];
	if (p[@"CompactIcons"]) DICompactIcons = [p[@"CompactIcons"] boolValue];
	if (p[@"Haptics"])      DIHaptics      = [p[@"Haptics"] boolValue];
	if (p[@"TopOffset"])    DITopOffset    = [p[@"TopOffset"] floatValue];
	if (p[@"AnimSpeed"])    DIAnimSpeed    = MAX(0.2, [p[@"AnimSpeed"] floatValue]);
	if (p[@"Swipes"])       DISwipes       = [p[@"Swipes"] boolValue];
	if (p[@"ShowCharging"]) DIShowCharging = [p[@"ShowCharging"] boolValue];
	if (p[@"FakeActivity"]) DIFake         = [p[@"FakeActivity"] boolValue];
}

static void DIPrefsCallback(CFNotificationCenterRef center, void *observer,
	CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	DILoadPrefs();
}

// Размеры как у настоящего острова 14 Pro (в поинтах)
static const CGFloat kPillW = 126.0, kPillH = 37.0;
static const CGFloat kCardHMedia = 150.0, kCardHCall = 112.0;
static CGFloat DICardWidth(void) {
	CGFloat w = [UIScreen mainScreen].bounds.size.width;
	return MIN(w - 16.0, 371.0);
}
static CGRect DIPillFrame(void) {
	CGFloat w = [UIScreen mainScreen].bounds.size.width;
	return CGRectMake((w - kPillW) / 2.0, DITopOffset, kPillW, kPillH);
}
static CGRect DICardFrame(CGFloat h) {
	CGFloat w = [UIScreen mainScreen].bounds.size.width;
	CGFloat cw = DICardWidth();
	return CGRectMake((w - cw) / 2.0, DITopOffset, cw, h);
}

// Приватный MediaRemote через dlopen — собирается публичным SDK.
// Команды: 2 = play/pause, 4 = next, 5 = prev (стабильные значения iOS 7–15).
static void DISendMediaCommand(NSInteger cmd) {
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

// ================= Waveform (живые столбики в пилюле) =================
@interface DIWaveView : UIView {
	NSMutableArray<UIView *> *_bars;
}
- (void)start;
- (void)stop;
@end

@implementation DIWaveView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		_bars = [NSMutableArray array];
		CGFloat bw = 3.0;
		for (int i = 0; i < 4; i++) {
			UIView *bar = [[UIView alloc] init];
			bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:(0.55 + 0.15 * (i % 2))];
			bar.layer.cornerRadius = bw / 2.0;
			// Якорь снизу — столбик растёт вверх
			bar.layer.anchorPoint = CGPointMake(0.5, 1.0);
			[self addSubview:bar];
			[_bars addObject:bar];
		}
		self.hidden = YES;
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat bw = 3.0, gap = 4.0, H = self.bounds.size.height;
	for (int i = 0; i < (int)_bars.count; i++) {
		UIView *bar = _bars[i];
		CGFloat x = i * (bw + gap);
		bar.bounds = CGRectMake(0, 0, bw, H);
		bar.layer.position = CGPointMake(x + bw / 2.0, H);
	}
}

- (void)start {
	self.hidden = NO;
	for (int i = 0; i < (int)_bars.count; i++) {
		UIView *bar = _bars[i];
		[bar.layer removeAnimationForKey:@"wave"];
		CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
		a.fromValue = @0.25;
		a.toValue = @1.0;
		a.duration = 0.42 + 0.13 * i; // рассинхрон — выглядит живо
		a.beginTime = CACurrentMediaTime() + 0.09 * i;
		a.autoreverses = YES;
		a.repeatCount = HUGE_VALF;
		a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
		[bar.layer addAnimation:a forKey:@"wave"];
	}
}

- (void)stop {
	for (UIView *bar in _bars) [bar.layer removeAnimationForKey:@"wave"];
	self.hidden = YES;
}

@end

// ================= Замок иконкой (рисуем сами, не эмодзи) =================
@interface DILockIconView : UIView
@property (nonatomic, assign) BOOL open; // открытый замок для анимации разблокировки
@end

@implementation DILockIconView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor = [UIColor clearColor];
		self.opaque = NO;
	}
	return self;
}

- (void)setOpen:(BOOL)open {
	_open = open;
	[self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
	CGFloat w = rect.size.width, h = rect.size.height;
	UIColor *white = [UIColor whiteColor];
	CGFloat lw = w * 0.15;
	CGFloat r = w * 0.25;
	CGPoint c = CGPointMake(w / 2.0, h * 0.40);
	CGFloat bodyTop = h * 0.40;

	[white setStroke];
	// Ножки дужки (у открытого — только левая)
	UIBezierPath *legs = [UIBezierPath bezierPath];
	[legs moveToPoint:CGPointMake(c.x - r, c.y)];
	[legs addLineToPoint:CGPointMake(c.x - r, bodyTop + lw * 0.4)];
	if (!_open) {
		[legs moveToPoint:CGPointMake(c.x + r, c.y)];
		[legs addLineToPoint:CGPointMake(c.x + r, bodyTop + lw * 0.4)];
	}
	legs.lineWidth = lw;
	[legs stroke];
	// Дуга (у открытого с разрывом справа)
	UIBezierPath *arc = [UIBezierPath bezierPath];
	if (!_open) {
		[arc addArcWithCenter:c radius:r startAngle:M_PI endAngle:0.0 clockwise:YES];
	} else {
		[arc addArcWithCenter:c radius:r startAngle:M_PI endAngle:-M_PI * 0.25 clockwise:YES];
	}
	arc.lineWidth = lw;
	arc.lineCapStyle = kCGLineCapRound;
	[arc stroke];
	// Корпус
	CGFloat bw = w * 0.58, bh = h * 0.50;
	CGRect body = CGRectMake((w - bw) / 2.0, bodyTop, bw, bh);
	UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:bw * 0.20];
	[white setFill];
	[bp fill];
	// Скважина
	CGFloat kr = w * 0.055;
	UIBezierPath *key = [UIBezierPath bezierPathWithArcCenter:CGPointMake(w / 2.0, bodyTop + bh * 0.38)
		radius:kr startAngle:0.0 endAngle:2.0 * M_PI clockwise:YES];
	[[UIColor blackColor] setFill];
	[key fill];
}

@end

// ================= Батарея иконкой (зарядка, не эмодзи) =================
@interface DIBatteryIconView : UIView
@property (nonatomic, assign) CGFloat level; // 0..1
@end

@implementation DIBatteryIconView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor = [UIColor clearColor];
		self.opaque = NO;
		_level = -1.0;
	}
	return self;
}

- (void)setLevel:(CGFloat)level {
	_level = level;
	[self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
	CGFloat w = rect.size.width, h = rect.size.height;
	CGFloat lw = MAX(2.0, w * 0.07);
	CGFloat capW = w * 0.09;
	CGFloat bodyW = w - capW - lw;
	CGFloat bodyH = h * 0.52;
	CGFloat bodyY = (h - bodyH) / 2.0;
	UIColor *white = [UIColor whiteColor];
	// Кончик
	CGFloat capH = bodyH * 0.42;
	UIBezierPath *cap = [UIBezierPath bezierPathWithRoundedRect:
		CGRectMake(lw / 2.0 + bodyW, (h - capH) / 2.0, capW, capH) cornerRadius:capW * 0.3];
	[white setFill];
	[cap fill];
	// Корпус
	UIBezierPath *out = [UIBezierPath bezierPathWithRoundedRect:
		CGRectMake(lw / 2.0, bodyY, bodyW, bodyH) cornerRadius:bodyH * 0.28];
	[white setStroke];
	out.lineWidth = lw;
	[out stroke];
	// Заливка по уровню
	CGFloat lvl = MIN(MAX(_level, 0.0), 1.0);
	if (lvl > 0.0) {
		CGFloat pad = lw + 2.0;
		CGFloat fw = (bodyW - pad * 2.0) * lvl;
		if (fw > 2.0) {
			UIBezierPath *fill = [UIBezierPath bezierPathWithRoundedRect:
				CGRectMake(lw / 2.0 + pad, bodyY + pad, fw, bodyH - pad * 2.0)
				cornerRadius:(bodyH - pad * 2.0) * 0.4];
			[[UIColor colorWithRed:0.2 green:0.85 blue:0.35 alpha:1.0] setFill];
			[fill fill];
		}
	}
}

@end

// ================= Вид острова =================
typedef NS_ENUM(NSInteger, DIContentType) {
	DIContentNone = 0,
	DIContentMedia,
	DIContentCall,
	DIContentLock,
};

@interface DIIslandView : UIView
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL compactEnabled;
@property (nonatomic, assign) DIContentType contentType;
@property (nonatomic, strong) UIView *liveDot;
// карточка
@property (nonatomic, strong) UIView *cardContent;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *iconLabel;
// компакт (свёрнутая пилюля с контентом)
@property (nonatomic, strong) UIView *compactContent;
@property (nonatomic, strong) UILabel *compactIcon;
@property (nonatomic, strong) DIWaveView *compactWave;
@property (nonatomic, strong) DILockIconView *cardLock;
@property (nonatomic, strong) DILockIconView *compactLock;
@property (nonatomic, strong) DIBatteryIconView *cardBattery;
@property (nonatomic, strong) DIBatteryIconView *compactBattery;
@property (nonatomic, assign) CGFloat batteryLevel;
- (void)setContent:(DIContentType)type title:(NSString *)title subtitle:(NSString *)sub artwork:(UIImage *)art;
- (void)setLockOpen:(BOOL)open;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
@end

@implementation DIIslandView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor = [UIColor blackColor];
		self.layer.cornerRadius = kPillH / 2.0;
		self.layer.masksToBounds = YES;
		self.userInteractionEnabled = YES;
		_compactEnabled = YES;

		_liveDot = [[UIView alloc] initWithFrame:CGRectMake(kPillW - 30, (kPillH - 10) / 2.0, 10, 10)];
		_liveDot.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.35 alpha:1.0];
		_liveDot.layer.cornerRadius = 5.0;
		_liveDot.alpha = 0.0;
		[self addSubview:_liveDot];

		// --- компактный слой пилюли ---
		_compactContent = [[UIView alloc] init];
		_compactContent.alpha = 0.0;
		[self addSubview:_compactContent];

		_compactIcon = [[UILabel alloc] init];
		_compactIcon.font = [UIFont systemFontOfSize:20.0];
		_compactIcon.textAlignment = NSTextAlignmentCenter;
		[_compactContent addSubview:_compactIcon];

		_compactWave = [[DIWaveView alloc] init];
		[_compactContent addSubview:_compactWave];
		_compactLock = [[DILockIconView alloc] init];
		_compactLock.hidden = YES;
		[_compactContent addSubview:_compactLock];
		_compactBattery = [[DIBatteryIconView alloc] init];
		_compactBattery.hidden = YES;
		[_compactContent addSubview:_compactBattery];

		// --- слой карточки ---
		_cardContent = [[UIView alloc] init];
		_cardContent.alpha = 0.0;
		[self addSubview:_cardContent];

		_artworkView = [[UIImageView alloc] init];
		_artworkView.layer.cornerRadius = 12.0;
		_artworkView.layer.masksToBounds = YES;
		_artworkView.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
		[_cardContent addSubview:_artworkView];

		_iconLabel = [[UILabel alloc] init];
		_iconLabel.font = [UIFont systemFontOfSize:30.0];
		_iconLabel.textAlignment = NSTextAlignmentCenter;
		[_cardContent addSubview:_iconLabel];
		_cardLock = [[DILockIconView alloc] init];
		_cardLock.hidden = YES;
		[_cardContent addSubview:_cardLock];
		_cardBattery = [[DIBatteryIconView alloc] init];
		_cardBattery.hidden = YES;
		[_cardContent addSubview:_cardBattery];

		_titleLabel = [[UILabel alloc] init];
		_titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
		_titleLabel.textColor = [UIColor whiteColor];
		_titleLabel.numberOfLines = 1;
		[_cardContent addSubview:_titleLabel];

		_subtitleLabel = [[UILabel alloc] init];
		_subtitleLabel.font = [UIFont systemFontOfSize:13.0];
		_subtitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
		_subtitleLabel.numberOfLines = 1;
		[_cardContent addSubview:_subtitleLabel];

		UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
		[self addGestureRecognizer:tap];
		UISwipeGestureRecognizer *swLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeLeft)];
		swLeft.direction = UISwipeGestureRecognizerDirectionLeft;
		[self addGestureRecognizer:swLeft];
		UISwipeGestureRecognizer *swRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeRight)];
		swRight.direction = UISwipeGestureRecognizerDirectionRight;
		[self addGestureRecognizer:swRight];
	}
	return self;
}

- (void)handleTap {
	[[NSNotificationCenter defaultCenter] postNotificationName:@"DIIslandTapped" object:nil];
}

- (void)handleSwipeLeft {
	[[NSNotificationCenter defaultCenter] postNotificationName:@"DIIslandSwipeLeft" object:nil];
}

- (void)handleSwipeRight {
	[[NSNotificationCenter defaultCenter] postNotificationName:@"DIIslandSwipeRight" object:nil];
}

- (void)setContent:(DIContentType)type title:(NSString *)title subtitle:(NSString *)sub artwork:(UIImage *)art {
	_contentType = type;
	if (type == DIContentNone) {
		[self stopPulse];
		[_compactWave stop];
		_cardLock.hidden = YES;
		_compactLock.hidden = YES;
		_cardBattery.hidden = YES;
		_compactBattery.hidden = YES;
		[UIView animateWithDuration:0.25 animations:^{
			self.liveDot.alpha = 0.0;
			self.compactContent.alpha = 0.0;
		}];
		return;
	}
	_titleLabel.text = title ?: @"";
	_subtitleLabel.text = sub ?: @"";
	if (type == DIContentMedia) {
		_iconLabel.hidden = (art != nil);
		_artworkView.hidden = (art == nil);
		_artworkView.image = art;
		_compactIcon.text = @"🎵";
		_compactIcon.hidden = NO;
		_compactLock.hidden = YES;
		_cardLock.hidden = YES;
		_cardBattery.hidden = YES;
		_compactBattery.hidden = YES;
		_compactWave.hidden = NO;
	} else if (type == DIContentCall) {
		_iconLabel.hidden = NO;
		_artworkView.hidden = YES;
		_iconLabel.text = @"📞";
		_compactIcon.text = @"📞";
		_compactIcon.hidden = NO;
		_compactLock.hidden = YES;
		_cardLock.hidden = YES;
		_cardBattery.hidden = YES;
		_compactBattery.hidden = YES;
		[_compactWave stop];
	} else if (type == DIContentCharging) { // зарядка — широкий бар с иконкой батареи
		_iconLabel.hidden = YES;
		_artworkView.hidden = YES;
		_cardLock.hidden = YES;
		_cardBattery.hidden = NO;
		_cardBattery.level = _batteryLevel;
		_compactIcon.hidden = YES;
		_compactLock.hidden = YES;
		_compactBattery.hidden = NO;
		_compactBattery.level = _batteryLevel;
		[_compactWave stop];
	} else { // DIContentLock — рисованная иконка, не эмодзи
		_iconLabel.hidden = YES;
		_artworkView.hidden = YES;
		_cardLock.hidden = NO;
		_cardLock.open = NO;
		_cardBattery.hidden = YES;
		_compactIcon.hidden = YES;
		_compactLock.hidden = NO;
		_compactLock.open = NO;
		_compactBattery.hidden = YES;
		[_compactWave stop];
	}
	// Мгновенно показываем компакт, плавность — в схлопывании/раскрытии
	[self applyAlphasAnimated:NO];
}

- (void)setLockOpen:(BOOL)open {
	_cardLock.open = open;
	_compactLock.open = open;
}

- (void)applyAlphasAnimated:(BOOL)animated {
	BOOL has = _contentType != DIContentNone;
	BOOL showCompact = has && !_expanded && _compactEnabled;
	BOOL showDot = has && (!showCompact || _contentType == DIContentCall || _contentType == DIContentCharging);
	void (^apply)(void) = ^{
		self.cardContent.alpha = _expanded && has ? 1.0 : 0.0;
		self.compactContent.alpha = showCompact ? 1.0 : 0.0;
		self.liveDot.alpha = showDot ? 1.0 : 0.0;
	};
	if (animated) {
		[UIView animateWithDuration:0.25 animations:apply];
	} else {
		apply();
	}
	// Живые анимации: wave только в компакте музыки, пульс — в компакте звонка
	if (_contentType == DIContentMedia && showCompact) [_compactWave start];
	else [_compactWave stop];
	if (_contentType == DIContentCall && !_expanded) [self startPulse];
	else [self stopPulse];
}

- (void)startPulse {
	if ([_liveDot.layer animationForKey:@"pulse"]) return;
	CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
	a.fromValue = @1.0;
	a.toValue = @0.25;
	a.duration = 0.7;
	a.autoreverses = YES;
	a.repeatCount = HUGE_VALF;
	[_liveDot.layer addAnimation:a forKey:@"pulse"];
}

- (void)stopPulse {
	[_liveDot.layer removeAnimationForKey:@"pulse"];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
	_compactContent.frame = self.bounds;
	_cardContent.frame = self.bounds;
	// Компакт: иконка слева, wave справа
	_compactIcon.frame = CGRectMake(16, (kPillH - 24) / 2.0, 24, 24);
	_compactLock.frame = _compactIcon.frame;
	_compactBattery.frame = _compactIcon.frame;
	_compactWave.frame = CGRectMake(W - 16 - 25, (kPillH - 16) / 2.0, 25, 16);
	if (H <= kPillH + 1.0) return;
	// Карточка: иконка слева, тексты справа
	CGFloat pad = 18.0, iconSize = 56.0;
	CGFloat iconY = (H - iconSize) / 2.0;
	_artworkView.frame = CGRectMake(pad, iconY, iconSize, iconSize);
	_iconLabel.frame = _artworkView.frame;
	_cardLock.frame = _artworkView.frame;
	_cardBattery.frame = _artworkView.frame;
	CGFloat tx = pad + iconSize + 14.0, tw = W - tx - pad;
	_titleLabel.frame = CGRectMake(tx, iconY + 4.0, tw, 22.0);
	_subtitleLabel.frame = CGRectMake(tx, iconY + 28.0, tw, 20.0);
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
	_expanded = expanded;
	CGFloat speed = MAX(DIAnimSpeed, 0.2);
	CGFloat dur = (expanded ? 0.55 : 0.38) / speed;
	CGFloat targetR = !expanded ? kPillH / 2.0 : (_contentType == DIContentLock ? 27.0 : 30.0);
	if (!animated) {
		self.layer.cornerRadius = targetR;
		[self applyAlphasAnimated:NO];
		self.cardContent.transform = CGAffineTransformIdentity;
		return;
	}
	if (expanded) {
		// Контент подъезжает снизу с задержкой — как у настоящего острова
		self.cardContent.transform = CGAffineTransformMakeTranslation(0, 12);
	}
	[UIView animateWithDuration:dur delay:0.0 usingSpringWithDamping:(expanded ? 0.72 : 0.82)
		initialSpringVelocity:(expanded ? 0.55 : 0.4) options:0 animations:^{
			self.layer.cornerRadius = targetR;
		} completion:nil];
	[self applyAlphasAnimated:YES];
	if (expanded) {
		[UIView animateWithDuration:dur * 0.65 delay:0.1 options:UIViewAnimationOptionCurveEaseOut animations:^{
			self.cardContent.transform = CGAffineTransformIdentity;
		} completion:nil];
	}
}

@end

// ================= Менеджер =================
@interface DIIslandManager : NSObject <CXCallObserverDelegate>
@property (nonatomic, strong) UIWindow *islandWindow;
@property (nonatomic, strong) DIIslandView *island;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) CXCallObserver *callObserver;
@property (nonatomic, assign) BOOL hasCall;
@property (nonatomic, assign) BOOL mediaPlaying;
@property (nonatomic, copy) NSString *trackTitle;
@property (nonatomic, copy) NSString *trackArtist;
@property (nonatomic, strong) UIImage *trackArt;
@property (nonatomic, assign) BOOL installed;
@property (nonatomic, assign) BOOL chgActive;
@property (nonatomic, assign) BOOL chgFull;
@property (nonatomic, assign) CGFloat chgLevel;
@property (nonatomic, assign) NSTimeInterval lastUnlock;
+ (instancetype)shared;
- (void)install;
@end

@implementation DIIslandManager

+ (instancetype)shared {
	static DIIslandManager *s = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[self alloc] init]; });
	return s;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_callObserver = [[CXCallObserver alloc] init];
		[_callObserver setDelegate:self queue:dispatch_get_main_queue()];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTap)
			name:@"DIIslandTapped" object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSwipeLeft)
			name:@"DIIslandSwipeLeft" object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onSwipeRight)
			name:@"DIIslandSwipeRight" object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onRotate)
			name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
	}
	return self;
}

- (void)install {
	if (_installed) return;
	_installed = YES;

	CGRect pill = DIPillFrame();
	_islandWindow = [[UIWindow alloc] initWithFrame:pill];
	_islandWindow.windowLevel = UIWindowLevelStatusBar + 100;
	_islandWindow.backgroundColor = [UIColor clearColor];
	_islandWindow.hidden = NO;
	_islandWindow.userInteractionEnabled = YES;

	_island = [[DIIslandView alloc] initWithFrame:_islandWindow.bounds];
	_island.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_island.compactEnabled = DICompactIcons;
	[_islandWindow addSubview:_island];

	[UIDevice currentDevice].batteryMonitoringEnabled = YES;
	_pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
		selector:@selector(poll) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
	[self poll];
}

- (void)onRotate {
	if (_island.expanded) {
		DIContentType t = _island.contentType;
		_islandWindow.frame = DICardFrame((t == DIContentMedia) ? kCardHMedia : (t == DIContentCall ? kCardHCall : 56.0));
	} else {
		_islandWindow.frame = DIPillFrame();
	}
	_island.frame = _islandWindow.bounds;
}

- (void)onTap {
	if (!DIEnabled) return;
	// Пустая пилюля не раскрывается (только при активности), но пружинит
	if (_island.contentType == DIContentNone) {
		[UIView animateWithDuration:0.12 animations:^{
			self.island.transform = CGAffineTransformMakeScale(1.06, 1.12);
		} completion:^(BOOL f) {
			[UIView animateWithDuration:0.25 animations:^{
				self.island.transform = CGAffineTransformIdentity;
			}];
		}];
		return;
	}
	[self setExpanded:!_island.expanded animated:YES];
}

- (void)onSwipeLeft {
	if (!DIEnabled || !DISwipes) return;
	if (_island.contentType != DIContentMedia) return;
	DISendMediaCommand(5); // предыдущий трек
	[self haptic];
}

- (void)onSwipeRight {
	if (!DIEnabled || !DISwipes) return;
	if (_island.contentType != DIContentMedia) return;
	DISendMediaCommand(4); // следующий трек
	[self haptic];
}

- (void)haptic {
	if (!DIHaptics) return;
	UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc]
		initWithStyle:UIImpactFeedbackStyleMedium];
	[g prepare];
	[g impactOccurred];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
	DIContentType t = _island.contentType;
	// Замок — широкий низкий бар, а не высокая карточка
	CGFloat h = (t == DIContentMedia) ? kCardHMedia : (t == DIContentCall ? kCardHCall : 56.0);
	CGRect target = expanded ? DICardFrame(h) : DIPillFrame();
	_island.compactEnabled = DICompactIcons;
	if (expanded) [self haptic];
	if (animated) {
		CGFloat speed = MAX(DIAnimSpeed, 0.2);
		CGFloat dur = (expanded ? 0.55 : 0.38) / speed;
		// Тот же спринг, что и у скругления — окно и контент движутся синхронно
		[UIView animateWithDuration:dur delay:0.0 usingSpringWithDamping:(expanded ? 0.72 : 0.82)
			initialSpringVelocity:(expanded ? 0.55 : 0.4) options:0 animations:^{
				self.islandWindow.frame = target;
				self.island.frame = self.islandWindow.bounds;
				[self.island layoutIfNeeded];
			} completion:nil];
	} else {
		_islandWindow.frame = target;
		_island.frame = _islandWindow.bounds;
	}
	[_island setExpanded:expanded animated:animated];
}

- (void)poll {
	if (!DIEnabled) {
		_islandWindow.hidden = YES;
		return;
	}
	_islandWindow.hidden = NO;
	// TopOffset могли поменять в настройках — ровняем свёрнутую пилюлю
	if (!_island.expanded && !CGRectEqualToRect(_islandWindow.frame, DIPillFrame())) {
		_islandWindow.frame = DIPillFrame();
		_island.frame = _islandWindow.bounds;
	}

	NSDictionary *info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
	BOOL playing = NO;
	NSString *title = nil, *artist = nil;
	UIImage *art = nil;
	if (DIShowMedia && info) {
		NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
		playing = (rate && rate.doubleValue > 0.0);
		title = info[MPMediaItemPropertyTitle];
		artist = info[MPMediaItemPropertyArtist];
		MPMediaItemArtwork *aw = info[MPMediaItemPropertyArtwork];
		if (aw) {
			@try { art = [aw imageWithSize:CGSizeMake(112, 112)]; } @catch (__unused NSException *e) {}
		}
	}
	_mediaPlaying = playing;
	_trackTitle = [title copy];
	_trackArtist = [artist copy];
	_trackArt = art;

	// Батарея для анимации зарядки
	UIDevice *dev = [UIDevice currentDevice];
	_chgActive = (dev.batteryState == UIDeviceBatteryStateCharging
		|| dev.batteryState == UIDeviceBatteryStateFull);
	_chgFull = (dev.batteryState == UIDeviceBatteryStateFull);
	_chgLevel = dev.batteryLevel;
	_island.batteryLevel = _chgLevel;

	[self refresh];
}

- (void)refresh {
	[self refreshForce:NO];
}

- (void)finishUnlock {
	_islandWindow.windowLevel = UIWindowLevelAlert + 100;
	[self refreshForce:YES];
}

- (void)refreshForce:(BOOL)force {
	if (!force && _island.contentType == DIContentLock) return; // замком управляют didLock/didUnlock
	DIContentType want = DIContentNone;
	NSString *t = nil, *s = nil;
	UIImage *a = nil;
	if (DIShowCalls && _hasCall) {
		want = DIContentCall;
		t = @"Телефонный звонок";
		s = @"Нажмите, чтобы раскрыть";
	} else if (DIShowMedia && _mediaPlaying) {
		want = DIContentMedia;
		t = _trackTitle ?: @"Музыка";
		s = _trackArtist ?: @"Сейчас играет";
		a = _trackArt;
	} else if (DIShowCharging && _chgActive) {
		want = DIContentCharging;
		int pct = (int)round(MAX(_chgLevel, 0.0) * 100.0);
		t = [NSString stringWithFormat:@"%d%%", pct];
		s = _chgFull ? @"Заряжено" : @"Заряжается";
	}
	if (want == DIContentNone && DIFake) {
		want = DIContentMedia;
		t = @"Тестовый трек";
		s = @"Фейк-активность для превью";
		a = nil;
	}
	// Зарядка: проценты обновляем тихо, без перераскрытия
	if (want == DIContentCharging && want == _island.contentType) {
		_island.batteryLevel = _chgLevel;
		[_island setContent:want title:t subtitle:s artwork:nil];
		return;
	}

	BOOL contentChanged = (want != _island.contentType)
		|| (want == DIContentMedia && (![t isEqualToString:_island.titleLabel.text]));
	if (contentChanged) {
		[_island setContent:want title:t subtitle:s artwork:a];
		if (want != DIContentNone) {
			[self setExpanded:YES animated:YES];
			if (want == DIContentMedia) {
				[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoCollapse) object:nil];
				[self performSelector:@selector(autoCollapse) withObject:nil afterDelay:5.0];
			} else if (want == DIContentCharging) {
				[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoCollapse) object:nil];
				[self performSelector:@selector(autoCollapse) withObject:nil afterDelay:4.0];
			}
		} else {
			[self setExpanded:NO animated:YES];
		}
	}
}

- (void)autoCollapse {
	if (_island.contentType == DIContentLock) return;
	if (_island.contentType != DIContentNone && _island.expanded) {
		[self setExpanded:NO animated:YES];
	}
}

- (void)didLock {
	// Экран заблокировали — остров раскрывается с замком и текущим временем
	if (!DIEnabled) return;
	static NSDateFormatter *tf = nil;
	if (!tf) {
		tf = [[NSDateFormatter alloc] init];
		tf.dateFormat = @"HH:mm";
	}
	NSString *now = [tf stringFromDate:[NSDate date]];
	[_island setContent:DIContentLock title:@"Заблокировано" subtitle:now artwork:nil];
	_islandWindow.windowLevel = 100000; // поверх локскрина
	[self setExpanded:YES animated:YES];
}

- (void)didUnlock {
	// Разблокировка — замок morph'ится в открытый и остров схлопывается
	if (!DIEnabled) return;
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	if (now - _lastUnlock < 1.2) return; // хук + нотификация дублируют событие
	_lastUnlock = now;
	[self haptic];
	[_island setContent:DIContentLock title:@"Разблокировано" subtitle:@"" artwork:nil];
	[_island setLockOpen:YES];
	[self setExpanded:YES animated:YES];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(finishUnlock) object:nil];
	[self performSelector:@selector(finishUnlock) withObject:nil afterDelay:0.9];
}

#pragma mark - CXCallObserverDelegate
- (void)callObserver:(CXCallObserver *)callObserver callChanged:(CXCall *)call {
	_hasCall = !call.hasEnded;
	[self refresh];
	if (_hasCall && DIShowCalls && DIEnabled) {
		[self setExpanded:YES animated:YES];
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoCollapse) object:nil];
		[self performSelector:@selector(autoCollapse) withObject:nil afterDelay:6.0];
	}
}

@end

// Локстейт через notify — дублирует хуки SBLockScreenManager на случай,
// если селекторы не завелись на конкретной версии (state != 0 = заблокирован)
static void DIWatchLockState(void) {
	static int token = 0;
	notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) {
		uint64_t state = 0;
		notify_get_state(token, &state);
		if (state) [[DIIslandManager shared] didLock];
		else [[DIIslandManager shared] didUnlock];
	});
}

// Замок/разблокировка (SBLockScreenManager есть на всех iOS 12–15)
// ================= Точка входа =================
%hook SBLockScreenManager
- (void)lockUIFromSource:(int)source withOptions:(id)options {
	%orig;
	[[DIIslandManager shared] didLock];
}
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
	%orig;
	[[DIIslandManager shared] didUnlock];
}
%end

%ctor {
	DILoadPrefs();
	DIWatchLockState();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		DIPrefsCallback, CFSTR("com.listrise.dinapenis/prefs.changed"),
		NULL, CFNotificationSuspensionBehaviorCoalesce);

	[[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
		object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{
					[[DIIslandManager shared] install];
				});
		}];
}
