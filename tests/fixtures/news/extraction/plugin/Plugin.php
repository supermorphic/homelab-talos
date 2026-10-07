<?php
namespace Fixture;
final class Plugin implements \Composer\Plugin\PluginInterface {
    public function activate(\Composer\Composer $composer, \Composer\IO\IOInterface $io): void { file_put_contents('/work/plugin-executed', 'unsafe'); }
    public function deactivate(\Composer\Composer $composer, \Composer\IO\IOInterface $io): void {}
    public function uninstall(\Composer\Composer $composer, \Composer\IO\IOInterface $io): void {}
}
