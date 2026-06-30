uv run python -c "
from pathlib import Path
cwd = Path.cwd()
found_src = next(cwd.glob('**/@/components/ui/button.tsx'), None)

if found_src:
    frontend_dir = found_src.parent.parent.parent.parent
    target_dir = frontend_dir / 'src' / 'components' / 'ui'
    target_dir.mkdir(parents=True, exist_ok=True)
    target_file = target_dir / 'button.tsx'
    found_src.rename(target_file)
    print(f'Successfully moved: {target_file}')
    
    # Clean up empty '@' directory
    at_dir = found_src.parent.parent.parent
    import shutil
    shutil.rmtree(at_dir, ignore_errors=True)
else:
    print('button.tsx was not found in an accidental \"@\" directory.')
    # Check if already correctly positioned
    if next(cwd.glob('**/src/components/ui/button.tsx'), None):
        print('The file is already correctly placed inside \"src/components/ui/\"!')
"