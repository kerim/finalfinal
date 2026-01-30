Add-Type -AssemblyName PresentationFramework

$msg = @"
Really uninstall TeX Live?

Please make sure that no TeX Live programs are still running!
"@
$ans = [System.Windows.MessageBox]::Show($msg, 'Confirm uninstall', 'OKCancel', 'Question')
if ($ans -eq 1) {
  exit 0
} else {
  exit 1
}