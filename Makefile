VENV_DIR=.venv

PYTHON_PATH=$(PYTHONPATH)

.PHONY: setup venv install clean

setup: venv install

venv:
	@test -d $(VENV_DIR) || $(PYTHON_PATH) -m venv $(VENV_DIR)

install:
	@$(VENV_DIR)/bin/pip install --upgrade pip
	@$(VENV_DIR)/bin/pip install -r requirements.txt

clean:
	@rm -rf $(VENV_DIR)
