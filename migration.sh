cd backend

# 1. Generate the migration file automatically comparing the updated metadata
uv run alembic revision --autogenerate -m "alter_section_columns_to_text"

# 2. Apply the migration directly against your database
uv run alembic upgrade head