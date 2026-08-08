"""Packaging for the htmlsanitizer Python binding.

The engine .so is bundled INSIDE the wheel (package_data below), staged there
by python/.package.ae. That is what makes a plain `pip install` work with no
HTMLSANITIZER_LIB and no system-wide native install.
"""
from setuptools import setup, find_packages

setup(
    name="htmlsanitizer",
    version="0.1.0",
    description="Clean HTML of XSS vectors — thin binding over one shared native engine",
    long_description=open("README.md").read(),
    long_description_content_type="text/markdown",
    packages=find_packages(include=["htmlsanitizer", "htmlsanitizer.*"]),
    package_data={"htmlsanitizer": ["native/*.so", "native/*.dylib", "native/*.dll"]},
    include_package_data=True,
    python_requires=">=3.8",
    install_requires=[],
    classifiers=[
        "Programming Language :: Python :: 3",
        "Topic :: Text Processing :: Markup :: HTML",
        "Topic :: Security",
    ],
)
