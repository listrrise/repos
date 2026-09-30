#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// Жесты iPhone X отдельным твиком:
//  - полоска-индикатор снизу (только SpringBoard, поверх приложений),
//  - свайп вверх от нижнего края = домой (в каждом приложении),
//  - подъём контента (additionalSafeAreaInsets.bottom), чтобы полоска
//    не наезжала на кнопки.
// Один бинарник грузится в SpringBoard и во все UIKit-приложения,
// ветвление — по bundle id процесса.

static NSString *const kGPrefsPath = @"/var/mobile/Library/Preferences/com.listrise.dinapenis.plist";
static NSString *const kGPrefsChanged = @"com.listrise.dinapenis/prefs.changed";

static BOOL GEnabled = YES;
static NSInteger GBarColor = 0; // 0 авто (по теме), 1 белая, 2 чёрная
static CGFloat GInset = 20.0;

static void GLoadPrefs(void) {
	NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kGPrefsPath];
	if (!p) return;
	if (p[@"GestureEnabled"]) GEnabled = [p[@"GestureEnabled"] boolValue];
	if (p[@"BarColor"])       GBarColor = [p[@"BarColor"] integerValue];
	if (p[@"BottomInset"])    GInset = [p[@"BottomInset"] floatValue];
}

static void GPrefsCallback(CFNotificationCenterRef center, void *observer,
	CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	GLoadPrefs();
}

static BOOL GIsSpringBoard(void) {
	return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

// ================= Полоска (только SpringBoard) =================
@interface DGBarManager : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) NSTimer *timer;
+ (instancetype)shared;
- (void)install;
- (void)refresh;
@end

@implementation DGBarManager

+ (instancetype)shared {
	static DGBarManager *s = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[self alloc] init]; });
	return s;
}

- (CGRect)barFrame {
	CGSize s = [UIScreen mainScreen].bounds.size;
	return CGRectMake((s.width - 134.0) / 2.0, s.height - 13.0, 134.0, 5.0);
}

- (void)install {
	_window = [[UIWindow alloc] initWithFrame:[self barFrame]];
	_window.windowLevel = 500; // над окнами приложений, под статус-баром
	_window.backgroundColor = [UIColor clearColor];
	_window.userInteractionEnabled = NO; // только картинка; жест живёт в процессах приложений
	_window.hidden = NO;

	_bar = [[UIView alloc] initWithFrame:_window.bounds];
	_bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_bar.layer.cornerRadius = 2.5;
	[_window addSubview:_bar];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh)
		name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];

	[self refresh];
	_timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
		selector:@selector(refresh) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)refresh {
	if (!GEnabled) {
		_window.hidden = YES;
		return;
	}
	_window.hidden = NO;
	_window.frame = [self barFrame];
	_bar.frame = _window.bounds;

	UIColor *c = nil;
	if (GBarColor == 1) c = [UIColor whiteColor];
	else if (GBarColor == 2) c = [UIColor blackColor];
	else {
		// Авто: тёмная тема — белая полоска, светлая — чёрная
		c = (_window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)
			? [UIColor whiteColor] : [UIColor blackColor];
	}
	_bar.backgroundColor = [c colorWithAlphaComponent:0.92];
}

@end

// ================= Свайп вверх = домой (только приложения) =================
@interface DGAppHandler : NSObject
+ (instancetype)shared;
- (void)edgeFired:(UIScreenEdgePanGestureRecognizer *)pan;
@end

@implementation DGAppHandler

+ (instancetype)shared {
	static DGAppHandler *s = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[self alloc] init]; });
	return s;
}

- (void)edgeFired:(UIScreenEdgePanGestureRecognizer *)pan {
	if (pan.state == UIGestureRecognizerStateEnded && GEnabled) {
		[[UIApplication sharedApplication] suspend]; // свернуть приложение
	}
}

@end

static void DGAddEdgePan(UIWindow *w) {
	if (![w isKindOfClass:[UIWindow class]]) return;
	if (objc_getAssociatedObject(w, "DGEdge")) return; // уже висит
	UIScreenEdgePanGestureRecognizer *p = [[UIScreenEdgePanGestureRecognizer alloc]
		initWithTarget:[DGAppHandler shared] action:@selector(edgeFired:)];
	p.edges = UIRectEdgeBottom;
	[w addGestureRecognizer:p];
	objc_setAssociatedObject(w, "DGEdge", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void DGWatchWindows(void) {
	[[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
		object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
			DGAddEdgePan((UIWindow *)n.object);
		}];
	for (UIWindow *w in [UIApplication sharedApplication].windows) DGAddEdgePan(w);
}

// ================= Подъём контента (все, кроме SpringBoard и алертов) =================
%hook UIViewController
- (UIEdgeInsets)additionalSafeAreaInsets {
	UIEdgeInsets insets = %orig;
	if (GEnabled && !GIsSpringBoard() && ![self isKindOfClass:[UIAlertController class]]) {
		insets.bottom += GInset;
	}
	return insets;
}
%end

%ctor {
	GLoadPrefs();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		GPrefsCallback, CFSTR("com.listrise.dinapenis/prefs.changed"),
		NULL, CFNotificationSuspensionBehaviorCoalesce);

	if (GIsSpringBoard()) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{
				[[DGBarManager shared] install];
			});
	} else {
		DGWatchWindows();
	}
}
