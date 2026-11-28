// (Win10/Win11) let d3d12.dll load the app-local Agility SDK runtime in D3D12\ next to victory.exe; the
// Windows 10 inbox runtime rejects the root-signature flags this project sets, which makes every pipeline fail.
fn main() {
    println!("cargo:rustc-link-arg=/EXPORT:D3D12SDKVersion,DATA");
    println!("cargo:rustc-link-arg=/EXPORT:D3D12SDKPath,DATA");
}
