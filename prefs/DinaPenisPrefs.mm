#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>

@interface DinaPenisPrefsListController : PSListController
@end

@implementation DinaPenisPrefsListController

- (id)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

- (void)respring {
	// killall лежит в разных местах на rootful (/usr/bin) и rootless (/var/jb/usr/bin),
	// поэтому перебираем варианты. sbreload — запасной путь.
	const char *killalls[] = {
		"/var/jb/usr/bin/killall",
		"/usr/bin/killall",
		NULL
	};
	for (int i = 0; killalls[i]; i++) {
		pid_t pid;
		const char *args[] = { killalls[i], "SpringBoard", NULL };
		if (posix_spawn(&pid, killalls[i], NULL, NULL, (char *const *)args, NULL) == 0) return;
	}
	const char *reloads[] = {
		"/var/jb/usr/bin/sbreload",
		"/usr/bin/sbreload",
		NULL
	};
	for (int i = 0; reloads[i]; i++) {
		pid_t pid;
		const char *args[] = { reloads[i], NULL };
		if (posix_spawn(&pid, reloads[i], NULL, NULL, (char *const *)args, NULL) == 0) return;
	}
}

@end
