#import "CSPreferencesShim.h"

/// Every installed app, one row each, with its current CarPlay on/off state as
/// the row's trailing label. Tapping a row opens CSAppOptionsController,
/// which carries the enable switch itself along with layout and patch status —
/// this list exists to get the user there, not to toggle anything on its own.
@interface CSAppListController : PSListController
@end
