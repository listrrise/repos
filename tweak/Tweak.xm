#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CallKit/CallKit.h>

// ================= Prefs =================
static NSString *const kDIPrefsPath = @"/var/mobile/Library/Preferences/com.listrrise.dinapenis.plist";
static NSString *const kDIPrefsChanged = @"com.listrrise.dinapenis/prefs.changed";

static BOOL DIEnabled = YES;
static BOOL DIShowMedia = YES;
static BOOL DIShowCalls = YES;
static BOOL DICompactIcons = YES; // компактный контент в свёрнутой пилюле
static BOOL DIHaptics = YES;
static CGFloat DITopOffset = 11.0;
static CGFloat DIAnimSpeed = 1.0; // 0.5..1.5, 1.0 = норма

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

// ================= Вид острова =================
typedef NS_ENUM(NSInteger, DIContentType) {
	DIContentNone = 0,
	DIContentMedia,
	DIContentCall,
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
- (void)setContent:(DIContentType)type title:(NSString *)title subtitle:(NSString *)sub artwork:(UIImage *)art;
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
	}
	return self;
}

- (void)handleTap {
	[[NSNotificationCenter defaultCenter] postNotificationName:@"DIIslandTapped" object:nil];
}

- (void)setContent:(DIContentType)type title:(NSString *)title subtitle:(NSString *)sub artwork:(UIImage *)art {
	_contentType = type;
	if (type == DIContentNone) {
		[self stopPulse];
		[_compactWave stop];
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
		_compactWave.hidden = NO;
	} else {
		_iconLabel.hidden = NO;
		_artworkView.hidden = YES;
		_iconLabel.text = @"📞";
		_compactIcon.text = @"📞";
		[_compactWave stop];
	}
	// Мгновенно показываем компакт, плавность — в схлопывании/раскрытии
	[self applyAlphasAnimated:NO];
}

- (void)applyAlphasAnimated:(BOOL)animated {
	BOOL has = _contentType != DIContentNone;
	BOOL showCompact = has && !_expanded && _compactEnabled;
	BOOL showDot = has && (!showCompact || _contentType == DIContentCall);
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
	_compactWave.frame = CGRectMake(W - 16 - 25, (kPillH - 16) / 2.0, 25, 16);
	if (H <= kPillH + 1.0) return;
	// Карточка: иконка слева, тексты справа
	CGFloat pad = 18.0, iconSize = 56.0;
	CGFloat iconY = (H - iconSize) / 2.0;
	_artworkView.frame = CGRectMake(pad, iconY, iconSize, iconSize);
	_iconLabel.frame = _artworkView.frame;
	CGFloat tx = pad + iconSize + 14.0, tw = W - tx - pad;
	_titleLabel.frame = CGRectMake(tx, iconY + 4.0, tw, 22.0);
	_subtitleLabel.frame = CGRectMake(tx, iconY + 28.0, tw, 20.0);
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
	_expanded = expanded;
	CGFloat speed = MAX(DIAnimSpeed, 0.2);
	CGFloat dur = (expanded ? 0.55 : 0.38) / speed;
	CGFloat targetR = expanded ? 30.0 : kPillH / 2.0;
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

	_pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
		selector:@selector(poll) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
	[self poll];
}

- (void)onRotate {
	if (_island.expanded) {
		_islandWindow.frame = DICardFrame(_island.contentType == DIContentMedia ? kCardHMedia : kCardHCall);
	} else {
		_islandWindow.frame = DIPillFrame();
	}
	_island.frame = _islandWindow.bounds;
}

- (void)onTap {
	if (!DIEnabled) return;
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

- (void)haptic {
	if (!DIHaptics) return;
	UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc]
		initWithStyle:UIImpactFeedbackStyleMedium];
	[g prepare];
	[g impactOccurred];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
	CGFloat h = _island.contentType == DIContentMedia ? kCardHMedia : kCardHCall;
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

	[self refresh];
}

- (void)refresh {
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
			}
		} else {
			[self setExpanded:NO animated:YES];
		}
	}
}

- (void)autoCollapse {
	if (_island.contentType != DIContentNone && _island.expanded) {
		[self setExpanded:NO animated:YES];
	}
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

// ================= Точка входа =================
%ctor {
	DILoadPrefs();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		DIPrefsCallback, CFSTR("com.listrrise.dinapenis/prefs.changed"),
		NULL, CFNotificationSuspensionBehaviorCoalesce);

	[[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
		object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{
					[[DIIslandManager shared] install];
				});
		}];
}
