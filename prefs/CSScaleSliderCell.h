#import "CSPreferencesShim.h"

/// A slider row that keeps its value on the title line.
///
/// PSSliderCell's own `showValue` label is laid out beside the slider in the
/// space the title leaves, and at these widths it clips mid-digit — "0.50"
/// renders as "0.5" plus half a zero. Putting the value at the trailing end of
/// the title line instead gives it the whole width it needs, and matches
/// CSLayoutSegmentCell's shape so the section reads as one group of controls.
@interface CSScaleSliderCell : PSTableCell
@end
