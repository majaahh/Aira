enum FreeBudsCommand {
  controls,
  information,
  devices,
  locator,
  gesture,
  noiseCycle,
  feature,
  language,
  device,
  eq,
  fit,
}

abstract interface class FreeBudsService {
  Future<Map<String, dynamic>> runFreeBudsCommand(
    FreeBudsCommand command, [
    Map<String, Object> arguments = const {},
  ]);
}

const freeBudsEqPresets = {
  1: 'Default',
  2: 'Bass boost',
  3: 'Treble boost',
  9: 'Voices',
};
