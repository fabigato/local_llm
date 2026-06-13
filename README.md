# How to
## connect to openclaw:
Open webui settings are sql db first. You could setup add OLLAMA_BASE_URL=http://host.docker.internal:11434 or OPENAI_API_BASE_URL=http://openclaw:18789/v1 to the container environment variables but if you setup up a connection to a different llm in the ui, that will get saved in the litesql db and will take precedence over env vars. The db has user specific settings you don't want to commit, so commiting the db is not a good approach. Therefore, whatever changes you do in the ui will not be part of the containerized application and will have to be changed there in place. Here some useful settings You can put onder admin panel -> settings -> connections

### Connect to openclaw
Manage OpenAI API connections, add
URL: http://openclaw:18789/v1
Auth: Bearer (put your openclaw auth token)
API Type: Chat Completions

### Connect to local ollama
Manage Ollama API connections, add
URL: http://host.docker.internal:11434
Auth: None

## Hide openclaw models from users
You can't group them all under openclaw. Whether a model comes from ollama directly or openclaw, it's still just one model in the list. Permissions per model should be managed separately, using RBAC, so you can manually mark each openclaw model as private, only for some users and the rest as public or assign access to a group

## forward request headers to downstream llm
add env var:
ENABLE_FORWARD_USER_INFO_HEADERS=true