#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CallKit/CallKit.h>
#import <AVFoundation/AVFoundation.h>
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
	DIContentCharging,
};

@interface DIIslandView : UIView
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL compactEnabled;
@property (nonatomic, assign) DIContentType contentType;
@property (nonatomic, assign) BOOL privacyOn;
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
@property (nonatomic, strong) UILabel *compactPct;
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
		// Тонкая светлая окантовка — остров видно и на чёрном фоне
		self.layer.borderWidth = 1.5;
		self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25].CGColor;
		self.userInteractionEnabled = YES;
		_compactEnabled = YES;

		// liveDot удалён — мешал тексту

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
		_compactPct = [[UILabel alloc] init];
		_compactPct.font = [UIFont boldSystemFontOfSize:12.0];
		_compactPct.textColor = [UIColor whiteColor];
		_compactPct.textAlignment = NSTextAlignmentRight;
		_compactPct.hidden = YES;
		[_compactContent addSubview:_compactPct];

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
		[_compactWave stop];
		_cardLock.hidden = YES;
		_compactLock.hidden = YES;
		_cardBattery.hidden = YES;
		_compactBattery.hidden = YES;
		[UIView animateWithDuration:0.25 animations:^{
			self.compactContent.alpha = 0.0;
		}];
		return;
	}
	_titleLabel.text = title ?: @"";
	_subtitleLabel.text = sub ?: @"";
	_compactPct.hidden = (type != DIContentCharging);
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
		_compactPct.text = title; // title уже "82%"
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
	void (^apply)(void) = ^{
		self.cardContent.alpha = _expanded && has ? 1.0 : 0.0;
		self.compactContent.alpha = showCompact ? 1.0 : 0.0;
	};
	if (animated) {
		[UIView animateWithDuration:0.25 animations:apply];
	} else {
		apply();
	}
	// Wave только в компакте музыки
	if (_contentType == DIContentMedia && showCompact) [_compactWave start];
	else [_compactWave stop];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
	_compactContent.frame = self.bounds;
	_cardContent.frame = self.bounds;
	// Компакт: иконка слева, wave справа
	CGFloat iconX = _privacyOn ? 32.0 : 16.0; // точка приватности живёт слева
	_compactIcon.frame = CGRectMake(iconX, (kPillH - 24) / 2.0, 24, 24);
	_compactLock.frame = _compactIcon.frame;
	_compactBattery.frame = _compactIcon.frame;
	_compactWave.frame = CGRectMake(W - 16 - 25, (kPillH - 16) / 2.0, 25, 16);
	_compactPct.frame = CGRectMake(W - 16 - 44, (kPillH - 18) / 2.0, 44, 18);
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

// ================= Окно на весь экран, прозрачное для тапов =================
// Маленькое окно мешало бы кружку и точке за пределами пилюли,
// поэтому окно полноэкранное, а тапы пропускаем везде кроме острова/кружка/точки.
@interface DIIslandWindow : UIWindow
@property (nonatomic, weak) UIView *islandView;
@property (nonatomic, weak) UIView *miniView;
@property (nonatomic, weak) UIView *dotView;
@end

@implementation DIIslandWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	UIView *hit = [super hitTest:point withEvent:event];
	if (hit == self) return nil;
	if (hit == _islandView || hit == _miniView || hit == _dotView) return hit;
	if ([hit isDescendantOfView:_islandView] || [hit isDescendantOfView:_miniView]) return hit;
	return nil;
}

@end

// ================= Менеджер =================
@interface DIIslandManager : NSObject <CXCallObserverDelegate>
@property (nonatomic, strong) DIIslandWindow *islandWindow;
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
@property (nonatomic, assign) BOOL locked;
@property (nonatomic, assign) BOOL noAutoExpand;
@property (nonatomic, assign) BOOL camActive;
@property (nonatomic, assign) BOOL micActive;
@property (nonatomic, assign) DIContentType secondary;
@property (nonatomic, assign) BOOL swapped;
@property (nonatomic, copy) NSString *lastActKey;
@property (nonatomic, strong) UIView *miniView;
@property (nonatomic, strong) UILabel *miniIcon;
@property (nonatomic, strong) UIImageView *miniArt;
@property (nonatomic, strong) DIBatteryIconView *miniBattery;
@property (nonatomic, strong) UIView *privacyDot;
+ (instancetype)shared;
- (void)install;
- (void)layoutOverlaysAnimated:(BOOL)animated;
- (void)setCamActive:(BOOL)active;
- (void)setMicActive:(BOOL)active;
- (void)swapPrimary;
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

	_islandWindow = [[DIIslandWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	_islandWindow.windowLevel = UIWindowLevelAlert + 100;
	_islandWindow.backgroundColor = [UIColor clearColor];
	_islandWindow.hidden = NO;
	_islandWindow.userInteractionEnabled = YES;

	_island = [[DIIslandView alloc] initWithFrame:DIPillFrame()];
	_island.compactEnabled = DICompactIcons;
	[_islandWindow addSubview:_island];
	_islandWindow.islandView = _island;

	// Кружок второй активности справа от острова (тап — поменять местами)
	_miniView = [[UIView alloc] initWithFrame:CGRectZero];
	_miniView.backgroundColor = [UIColor blackColor];
	_miniView.layer.cornerRadius = 18.5;
	_miniView.layer.masksToBounds = YES;
	_miniView.layer.borderWidth = 1.5;
	_miniView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25].CGColor;
	_miniView.alpha = 0.0;
	[_islandWindow addSubview:_miniView];
	_islandWindow.miniView = _miniView;
	_miniIcon = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 37, 37)];
	_miniIcon.font = [UIFont systemFontOfSize:20.0];
	_miniIcon.textAlignment = NSTextAlignmentCenter;
	[_miniView addSubview:_miniIcon];
	_miniArt = [[UIImageView alloc] initWithFrame:CGRectMake(3, 3, 31, 31)];
	_miniArt.layer.cornerRadius = 15.5;
	_miniArt.layer.masksToBounds = YES;
	_miniArt.hidden = YES;
	[_miniView addSubview:_miniArt];
	_miniBattery = [[DIBatteryIconView alloc] initWithFrame:CGRectMake(6, 6, 25, 25)];
	_miniBattery.hidden = YES;
	[_miniView addSubview:_miniBattery];
	UITapGestureRecognizer *mtap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(swapPrimary)];
	[_miniView addGestureRecognizer:mtap];

	// Точка приватности (камера/микрофон)
	_privacyDot = [[UIView alloc] initWithFrame:CGRectZero];
	_privacyDot.layer.cornerRadius = 5.0;
	_privacyDot.alpha = 0.0;
	[_islandWindow addSubview:_privacyDot];
	_islandWindow.dotView = _privacyDot;

	[UIDevice currentDevice].batteryMonitoringEnabled = YES;
	_pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
		selector:@selector(poll) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
	[self poll];
}

- (void)onRotate {
	_islandWindow.frame = [UIScreen mainScreen].bounds;
	if (_island.expanded) {
		DIContentType t = _island.contentType;
		_island.frame = DICardFrame((t == DIContentMedia) ? kCardHMedia : (t == DIContentCall ? kCardHCall : 56.0));
	} else {
		_island.frame = DIPillFrame();
	}
	[self layoutOverlaysAnimated:NO];
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
		// Тот же спринг, что и у скругления — остров и оверлеи движутся синхронно
		[UIView animateWithDuration:dur delay:0.0 usingSpringWithDamping:(expanded ? 0.72 : 0.82)
			initialSpringVelocity:(expanded ? 0.55 : 0.4) options:0 animations:^{
				self.island.frame = target;
				[self.island layoutIfNeeded];
			} completion:nil];
		[self layoutOverlaysAnimated:YES];
	} else {
		_island.frame = target;
		[self layoutOverlaysAnimated:NO];
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
	if (!_island.expanded && !CGRectEqualToRect(_island.frame, DIPillFrame())) {
		_island.frame = DIPillFrame();
		[self layoutOverlaysAnimated:NO];
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
	_noAutoExpand = YES;
	[self refreshForce:YES];
	_noAutoExpand = NO;
	// После разблокировки только схлопываем — раскрывался один индикатор блокировки
	[self setExpanded:NO animated:YES];
	[self layoutOverlaysAnimated:NO];
}

- (void)refreshForce:(BOOL)force {
	if (!force && _island.contentType == DIContentLock) return; // замком управляют didLock/didUnlock
	// Мультиактивность по приоритету: звонок > музыка > зарядка
	NSMutableArray *acts = [NSMutableArray array];
	if (DIShowCalls && _hasCall) [acts addObject:@(DIContentCall)];
	if (DIShowMedia && _mediaPlaying) [acts addObject:@(DIContentMedia)];
	else if (DIShowCharging && _chgActive) [acts addObject:@(DIContentCharging)];
	if (acts.count == 0 && DIFake) [acts addObject:@(DIContentMedia)];
	NSString *key = [acts componentsJoinedByString:@","];
	if (![key isEqualToString:_lastActKey ?: @""]) { _swapped = NO; _lastActKey = [key copy]; }
	DIContentType primary = DIContentNone, secondary = DIContentNone;
	if (acts.count > 0) primary = (DIContentType)[acts[0] integerValue];
	if (acts.count > 1) secondary = (DIContentType)[acts[1] integerValue];
	if (_swapped && secondary != DIContentNone) {
		DIContentType tmp = primary; primary = secondary; secondary = tmp;
	}
	_secondary = secondary;

	NSString *t = nil, *s = nil;
	UIImage *a = nil;
	if (primary == DIContentCall) {
		t = @"Телефонный звонок";
		s = @"Нажмите, чтобы раскрыть";
	} else if (primary == DIContentMedia) {
		if (_mediaPlaying) {
			t = _trackTitle ?: @"Музыка";
			s = _trackArtist ?: @"Сейчас играет";
			a = _trackArt;
		} else {
			t = @"Тестовый трек";
			s = @"Фейк-активность для превью";
		}
	} else if (primary == DIContentCharging) {
		int pct = (int)round(MAX(_chgLevel, 0.0) * 100.0);
		t = [NSString stringWithFormat:@"%d%%", pct];
		s = _chgFull ? @"Заряжено" : @"Заряжается";
	}
	// Зарядка: проценты обновляем тихо, без перераскрытия
	if (primary == DIContentCharging && primary == _island.contentType) {
		_island.batteryLevel = _chgLevel;
		[_island setContent:primary title:t subtitle:s artwork:nil];
		[self layoutOverlaysAnimated:NO];
		return;
	}

	BOOL contentChanged = (primary != _island.contentType)
		|| (primary == DIContentMedia && (![t isEqualToString:_island.titleLabel.text]));
	if (contentChanged) {
		[_island setContent:primary title:t subtitle:s artwork:a];
		BOOL mayExpand = (primary != DIContentNone && !_locked && !_noAutoExpand);
		if (mayExpand) {
			[self setExpanded:YES animated:YES];
			if (primary == DIContentMedia) {
				[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoCollapse) object:nil];
				[self performSelector:@selector(autoCollapse) withObject:nil afterDelay:5.0];
			} else if (primary == DIContentCharging) {
				[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoCollapse) object:nil];
				[self performSelector:@selector(autoCollapse) withObject:nil afterDelay:4.0];
			}
		} else if (!_locked && !_noAutoExpand) {
			[self setExpanded:NO animated:YES];
		}
		// на локскрине и в finishUnlock: только контент, раскрытием управляет вызывающий
	}
	[self layoutOverlaysAnimated:NO];
}

- (void)autoCollapse {
	if (_island.contentType == DIContentLock) return;
	if (_island.contentType != DIContentNone && _island.expanded) {
		[self setExpanded:NO animated:YES];
	}
}

- (void)didLock {
	// Экран заблокировали: активность уходит в мини, замок — мини-индикатор
	if (!DIEnabled) return;
	_locked = YES;
	static NSDateFormatter *tf = nil;
	if (!tf) {
		tf = [[NSDateFormatter alloc] init];
		tf.dateFormat = @"HH:mm";
	}
	NSString *now = [tf stringFromDate:[NSDate date]];
	[_island setContent:DIContentLock title:@"Заблокировано" subtitle:now artwork:nil];
	_islandWindow.windowLevel = 100000; // поверх локскрина
	[self setExpanded:NO animated:YES];
	[self layoutOverlaysAnimated:NO];
}

- (void)didUnlock {
	// Разблокировка — расширяется ТОЛЬКО индикатор блокировки, затем всё схлопывается
	if (!DIEnabled) return;
	_locked = NO;
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

- (void)setCamActive:(BOOL)active {
	_camActive = active;
	[self layoutOverlaysAnimated:YES];
}

- (void)setMicActive:(BOOL)active {
	_micActive = active;
	[self layoutOverlaysAnimated:YES];
}

- (void)swapPrimary {
	if (_secondary == DIContentNone || _island.expanded) return;
	_swapped = !_swapped;
	[self haptic];
	[self refreshForce:YES];
}

- (void)layoutOverlaysAnimated:(BOOL)animated {
	// --- мини-кружок второй активности (виден только в мини-режиме) ---
	BOOL showMini = (_secondary != DIContentNone && !_island.expanded && DIEnabled);
	CGRect pill = DIPillFrame();
	if (_secondary == DIContentCall) {
		_miniIcon.hidden = NO; _miniIcon.text = @"📞";
		_miniArt.hidden = YES; _miniBattery.hidden = YES;
	} else if (_secondary == DIContentMedia) {
		if (_trackArt && _mediaPlaying) {
			_miniArt.hidden = NO; _miniArt.image = _trackArt;
			_miniIcon.hidden = YES;
		} else {
			_miniIcon.hidden = NO; _miniIcon.text = @"🎵";
			_miniArt.hidden = YES;
		}
		_miniBattery.hidden = YES;
	} else if (_secondary == DIContentCharging) {
		_miniBattery.hidden = NO; _miniBattery.level = _chgLevel;
		_miniIcon.hidden = YES; _miniArt.hidden = YES;
	}
	void (^apply)(void) = ^{
		self.miniView.frame = CGRectMake(CGRectGetMaxX(pill) + 8.0, pill.origin.y, 37.0, 37.0);
		self.miniView.alpha = showMini ? 1.0 : 0.0;
	};
	if (animated) {
		[UIView animateWithDuration:0.5 delay:0.0 usingSpringWithDamping:0.72
			initialSpringVelocity:0.5 options:0 animations:apply completion:nil];
	} else {
		apply();
	}
	[self layoutPrivacyDotAnimated:animated];
}

- (void)layoutPrivacyDotAnimated:(BOOL)animated {
	BOOL on = (_camActive || _micActive) && DIEnabled;
	UIColor *c = _camActive
		? [UIColor colorWithRed:0.2 green:0.85 blue:0.35 alpha:1.0]
		: [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0];
	CGRect f = _privacyDot.frame;
	CGFloat alpha = 0.0;
	if (on) {
		alpha = 1.0;
		if (_island.expanded) {
			// Вылезает слева из раскрытой карточки
			CGFloat cy = CGRectGetMidY(_island.frame);
			f = CGRectMake(_island.frame.origin.x - 14.0, cy - 5.0, 10.0, 10.0);
		} else {
			// Нет активности — рисуем прямо на острове (внутри пилюли слева)
			CGRect pill = _island.frame;
			f = CGRectMake(pill.origin.x + 12.0, pill.origin.y + (pill.size.height - 10.0) / 2.0, 10.0, 10.0);
		}
	}
	_island.privacyOn = on;
	[_island setNeedsLayout];
	BOOL popping = (on && _privacyDot.alpha < 0.5);
	if (popping) _privacyDot.transform = CGAffineTransformMakeScale(0.1, 0.1);
	_privacyDot.backgroundColor = c;
	void (^apply)(void) = ^{
		self.privacyDot.frame = f;
		self.privacyDot.alpha = alpha;
		self.privacyDot.transform = CGAffineTransformIdentity;
	};
	if (animated) {
		// Капля: пружина с отскоком
		[UIView animateWithDuration:0.55 delay:0.0 usingSpringWithDamping:0.6
			initialSpringVelocity:0.6 options:0 animations:apply completion:nil];
	} else {
		apply();
	}
}

#pragma mark - CXCallObserverDelegate
- (void)callObserver:(CXCallObserver *)callObserver callChanged:(CXCall *)call {
	_hasCall = !call.hasEnded;
	[self refresh];
	if (_hasCall && DIShowCalls && DIEnabled && !_locked) {
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

static BOOL DIIsSpringBoard(void) {
	return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

// Репорт камеры/микрофона из процессов приложений:
// в SpringBoard чужую активность сенсоров не видно, поэтому приложения
// шлют состояние через notify (state), SpringBoard слушает.
static int DICamCount = 0;
static BOOL DIMicOn = NO;

static void DIReportSensors(void) {
	uint32_t t = 0;
	notify_register_check("com.listrise.dinapenis.cam", &t);
	notify_set_state(t, DICamCount > 0 ? 1 : 0);
	notify_post("com.listrise.dinapenis.cam");
	notify_register_check("com.listrise.dinapenis.mic", &t);
	notify_set_state(t, DIMicOn ? 1 : 0);
	notify_post("com.listrise.dinapenis.mic");
}

%hook AVCaptureSession
- (void)startRunning {
	%orig;
	if (DIIsSpringBoard()) return;
	DICamCount++;
	DIReportSensors();
}
- (void)stopRunning {
	%orig;
	if (DIIsSpringBoard()) return;
	if (DICamCount > 0) DICamCount--;
	DIReportSensors();
}
%end

%hook AVAudioSession
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)error {
	BOOL ok = %orig;
	if (DIIsSpringBoard()) return ok;
	if (ok) {
		if (!active) {
			DIMicOn = NO;
		} else {
			NSString *cat = self.category;
			DIMicOn = [cat isEqualToString:AVAudioSessionCategoryRecord]
				|| [cat isEqualToString:AVAudioSessionCategoryPlayAndRecord]
				|| [cat isEqualToString:AVAudioSessionCategoryMultiRoute];
		}
		DIReportSensors();
	}
	return ok;
}
- (BOOL)setActive:(BOOL)active error:(NSError **)error {
	BOOL ok = %orig;
	if (DIIsSpringBoard()) return ok;
	if (ok && !active) { DIMicOn = NO; DIReportSensors(); }
	return ok;
}
%end

static void DIWatchSensors(void) {
	static int camT = 0, micT = 0;
	notify_register_dispatch("com.listrise.dinapenis.cam", &camT, dispatch_get_main_queue(), ^(int t) {
		uint64_t s = 0;
		notify_get_state(camT, &s);
		[[DIIslandManager shared] setCamActive:(s != 0)];
	});
	notify_register_dispatch("com.listrise.dinapenis.mic", &micT, dispatch_get_main_queue(), ^(int t) {
		uint64_t s = 0;
		notify_get_state(micT, &s);
		[[DIIslandManager shared] setMicActive:(s != 0)];
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
	// В приложениях грузимся только ради репорта камеры/микрофона,
	// весь остров живёт строго в SpringBoard.
	if (!DIIsSpringBoard()) return;
	DILoadPrefs();
	DIWatchLockState();
	DIWatchSensors();
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
