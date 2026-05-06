/*
 * Standalone reproducer for two bugs in res_odbc.c reload-under-load:
 *
 *   BUG_DELME_FILTER   — aoro2_class_cb skips classes with delme=1, so
 *                        during the brief window between marking all classes
 *                        delme=1 and load_odbc_config linking the new class,
 *                        every concurrent ast_odbc_request_obj() returns NULL.
 *
 *   BUG_REALLOC_CLASSES — load_odbc_config always allocates a new odbc_class
 *                         even when config didn't change, forcing the old
 *                         class (and its entire connection pool) to be torn
 *                         down. The new class starts with an empty pool, so
 *                         after each reload every concurrent thread has to
 *                         do a fresh "connect()" — a thundering herd.
 *
 * Two compile-time flags toggle each bug independently:
 *   -DBUG_DELME_FILTER=1 / =0
 *   -DBUG_REALLOC_CLASSES=1 / =0
 *
 * Build: see build.sh in this directory.
 *
 * The "connection" abstraction here is a counted resource with a fake
 * connect() latency. We do NOT need a real database to demonstrate the
 * bugs — they're entirely about the in-memory class lifecycle.
 */

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/queue.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef BUG_DELME_FILTER
#define BUG_DELME_FILTER 1
#endif
#ifndef BUG_REALLOC_CLASSES
#define BUG_REALLOC_CLASSES 1
#endif

/* Tunables. Defaults are picked to make the bug obvious without making the
 * test take forever. */
#define NUM_CLASSES         4      /* like having 4 ODBC sections in res_odbc.conf */
#define NUM_READERS         32     /* concurrent dialplan threads doing ODBC queries */
#define MAX_CONN_PER_CLASS  8      /* maxconnections per class */
#define TEST_DURATION_SEC   5
#define RELOAD_PERIOD_US    50000  /* fire a reload every 50 ms */
#define CONFIG_LOAD_LATENCY_US 2000 /* ast_config_load + parsing takes ~2 ms */
#define PER_CLASS_LINK_LATENCY_US 200 /* ao2_alloc + ao2_link per class ~200 us */
#define CONNECT_LATENCY_US   1500  /* SQLConnect round-trip */
#define WORK_LATENCY_US      300   /* simulated query execution */

/* ------------------------------------------------------------------- */

struct odbc_obj {
    int connected;          /* mock: set by fake connect() */
    LIST_ENTRY(odbc_obj) list;
};

LIST_HEAD(odbc_obj_list, odbc_obj);

struct odbc_class {
    char name[80];
    int delme;
    pthread_mutex_t lock;       /* protects connections + pool counters */
    struct odbc_obj_list connections;  /* the cache pool */
    int connection_cnt;         /* total live (in-use + cached) */
    int cached_cnt;             /* size of `connections` list */
    int maxconnections;
    LIST_ENTRY(odbc_class) container_entry;
    atomic_int refcount;
};

LIST_HEAD(class_list, odbc_class);

static struct class_list g_container = LIST_HEAD_INITIALIZER(g_container);
static pthread_mutex_t g_container_lock = PTHREAD_MUTEX_INITIALIZER;

static _Atomic int g_running = 1;

/* Metrics --------------------------------------------------------------- */
static atomic_uint_fast64_t m_lookup_ok           = 0;
static atomic_uint_fast64_t m_lookup_fail         = 0;
static atomic_uint_fast64_t m_pool_hit            = 0;  /* got cached conn */
static atomic_uint_fast64_t m_pool_miss_connect   = 0;  /* had to fake-connect */
static atomic_uint_fast64_t m_destructor_pool_drops = 0; /* connections destroyed by class destructor */
static atomic_uint_fast64_t m_reloads             = 0;

/* Helpers --------------------------------------------------------------- */

static void class_ref(struct odbc_class *c) { atomic_fetch_add(&c->refcount, 1); }

static void class_destructor(struct odbc_class *c)
{
    /* Mirror odbc_class_destructor: drop every cached connection. */
    struct odbc_obj *o;
    while ((o = LIST_FIRST(&c->connections)) != NULL) {
        LIST_REMOVE(o, list);
        atomic_fetch_add(&m_destructor_pool_drops, 1);
        free(o);
    }
    pthread_mutex_destroy(&c->lock);
    free(c);
}

static void class_unref(struct odbc_class *c)
{
    if (atomic_fetch_sub(&c->refcount, 1) == 1) {
        class_destructor(c);
    }
}

/* Mirror of res_odbc.c::aoro2_class_cb + ao2_callback. */
static struct odbc_class *find_class(const char *name)
{
    struct odbc_class *c, *found = NULL;
    pthread_mutex_lock(&g_container_lock);
    LIST_FOREACH(c, &g_container, container_entry) {
        if (strcmp(c->name, name) != 0) continue;
#if BUG_DELME_FILTER
        if (c->delme) continue;
#endif
        class_ref(c);
        found = c;
        break;
    }
    pthread_mutex_unlock(&g_container_lock);
    return found;
}

static struct odbc_class *make_class(const char *name)
{
    struct odbc_class *c = calloc(1, sizeof(*c));
    snprintf(c->name, sizeof(c->name), "%s", name);
    pthread_mutex_init(&c->lock, NULL);
    LIST_INIT(&c->connections);
    c->maxconnections = MAX_CONN_PER_CLASS;
    atomic_init(&c->refcount, 1);  /* container's reference */
    return c;
}

/* Mirror of _ast_odbc_request_obj2: take from cache, or fake-connect. */
static struct odbc_obj *request_obj(struct odbc_class *c)
{
    pthread_mutex_lock(&c->lock);
    struct odbc_obj *o = LIST_FIRST(&c->connections);
    if (o) {
        LIST_REMOVE(o, list);
        c->cached_cnt--;
        pthread_mutex_unlock(&c->lock);
        atomic_fetch_add(&m_pool_hit, 1);
        return o;
    }
    if (c->connection_cnt >= c->maxconnections) {
        /* In real code we'd ast_cond_wait. For the repro, just fail. */
        pthread_mutex_unlock(&c->lock);
        return NULL;
    }
    c->connection_cnt++;
    pthread_mutex_unlock(&c->lock);

    /* Fake connect — slow. */
    usleep(CONNECT_LATENCY_US);
    o = calloc(1, sizeof(*o));
    o->connected = 1;
    atomic_fetch_add(&m_pool_miss_connect, 1);
    return o;
}

static void release_obj(struct odbc_class *c, struct odbc_obj *o)
{
    pthread_mutex_lock(&c->lock);
    LIST_INSERT_HEAD(&c->connections, o, list);
    c->cached_cnt++;
    pthread_mutex_unlock(&c->lock);
}

/* ------------------------------------------------------------------- */
/* Reload: mirrors res_odbc.c::reload() + load_odbc_config().          */
/* ------------------------------------------------------------------- */

/* Existing class lookup used by the FIXED preserve-path. */
#if !BUG_REALLOC_CLASSES
static struct odbc_class *find_class_for_reload(const char *name)
{
    struct odbc_class *c;
    /* Caller must hold container lock. */
    LIST_FOREACH(c, &g_container, container_entry) {
        if (strcmp(c->name, name) == 0) {
            return c;
        }
    }
    return NULL;
}
#endif

static void reload(void)
{
    /* Step 1: mark all delme=1. */
    pthread_mutex_lock(&g_container_lock);
    struct odbc_class *c;
    LIST_FOREACH(c, &g_container, container_entry) {
        c->delme = 1;
    }
    pthread_mutex_unlock(&g_container_lock);

    /* Step 2: load_odbc_config. Simulates ast_config_load + parsing latency. */
    usleep(CONFIG_LOAD_LATENCY_US);

    for (int i = 0; i < NUM_CLASSES; i++) {
        char name[64];
        snprintf(name, sizeof(name), "class_%d", i);

#if BUG_REALLOC_CLASSES
        /* Buggy path: always alloc a fresh class. */
        struct odbc_class *new_c = make_class(name);
        usleep(PER_CLASS_LINK_LATENCY_US);
        pthread_mutex_lock(&g_container_lock);
        LIST_INSERT_HEAD(&g_container, new_c, container_entry);
        pthread_mutex_unlock(&g_container_lock);
#else
        /* Fixed path: if a class with this name already exists with the
         * same connection-affecting config, just clear delme. Otherwise
         * alloc a new one. */
        usleep(PER_CLASS_LINK_LATENCY_US);
        pthread_mutex_lock(&g_container_lock);
        struct odbc_class *existing = find_class_for_reload(name);
        if (existing && existing->maxconnections == MAX_CONN_PER_CLASS) {
            existing->delme = 0;
        } else {
            struct odbc_class *new_c = make_class(name);
            LIST_INSERT_HEAD(&g_container, new_c, container_entry);
        }
        pthread_mutex_unlock(&g_container_lock);
#endif
    }

    /* Step 3: cleanup — unlink all classes still marked delme. */
    pthread_mutex_lock(&g_container_lock);
    struct odbc_class *next;
    c = LIST_FIRST(&g_container);
    while (c) {
        next = LIST_NEXT(c, container_entry);
        if (c->delme) {
            LIST_REMOVE(c, container_entry);
            pthread_mutex_unlock(&g_container_lock);
            class_unref(c);  /* drop container's ref */
            pthread_mutex_lock(&g_container_lock);
        }
        c = next;
    }
    pthread_mutex_unlock(&g_container_lock);

    atomic_fetch_add(&m_reloads, 1);
}

/* ------------------------------------------------------------------- */
/* Threads                                                              */
/* ------------------------------------------------------------------- */

static void *reader_thread(void *arg)
{
    unsigned int seed = (unsigned int)(uintptr_t)arg;
    while (atomic_load_explicit(&g_running, memory_order_relaxed)) {
        char name[64];
        snprintf(name, sizeof(name), "class_%d", rand_r(&seed) % NUM_CLASSES);

        struct odbc_class *c = find_class(name);
        if (!c) {
            atomic_fetch_add(&m_lookup_fail, 1);
            usleep(50);
            continue;
        }
        atomic_fetch_add(&m_lookup_ok, 1);

        struct odbc_obj *o = request_obj(c);
        if (o) {
            usleep(WORK_LATENCY_US);
            release_obj(c, o);
        }
        class_unref(c);
    }
    return NULL;
}

static void *reload_thread(void *unused)
{
    (void)unused;
    while (atomic_load_explicit(&g_running, memory_order_relaxed)) {
        reload();
        usleep(RELOAD_PERIOD_US);
    }
    return NULL;
}

/* ------------------------------------------------------------------- */

static void seed_initial_classes(void)
{
    pthread_mutex_lock(&g_container_lock);
    for (int i = 0; i < NUM_CLASSES; i++) {
        char name[64];
        snprintf(name, sizeof(name), "class_%d", i);
        struct odbc_class *c = make_class(name);
        LIST_INSERT_HEAD(&g_container, c, container_entry);
    }
    pthread_mutex_unlock(&g_container_lock);
}

int main(int argc, char **argv)
{
    int duration = TEST_DURATION_SEC;
    if (argc > 1) duration = atoi(argv[1]);

    fprintf(stderr,
            "config: BUG_DELME_FILTER=%d  BUG_REALLOC_CLASSES=%d  "
            "duration=%ds  readers=%d  classes=%d  max_conn=%d  reload_period=%dms\n",
            BUG_DELME_FILTER, BUG_REALLOC_CLASSES,
            duration, NUM_READERS, NUM_CLASSES, MAX_CONN_PER_CLASS,
            RELOAD_PERIOD_US / 1000);

    seed_initial_classes();

    pthread_t readers[NUM_READERS];
    for (int i = 0; i < NUM_READERS; i++) {
        pthread_create(&readers[i], NULL, reader_thread, (void *)(uintptr_t)(i + 1));
    }
    pthread_t reloader;
    pthread_create(&reloader, NULL, reload_thread, NULL);

    sleep(duration);
    atomic_store_explicit(&g_running, 0, memory_order_relaxed);

    for (int i = 0; i < NUM_READERS; i++) pthread_join(readers[i], NULL);
    pthread_join(reloader, NULL);

    /* Drain remaining classes so destructor counts pool drops. */
    pthread_mutex_lock(&g_container_lock);
    struct odbc_class *c, *next;
    c = LIST_FIRST(&g_container);
    while (c) {
        next = LIST_NEXT(c, container_entry);
        LIST_REMOVE(c, container_entry);
        pthread_mutex_unlock(&g_container_lock);
        class_unref(c);
        pthread_mutex_lock(&g_container_lock);
        c = next;
    }
    pthread_mutex_unlock(&g_container_lock);

    uint64_t lookup_ok = atomic_load(&m_lookup_ok);
    uint64_t lookup_fail = atomic_load(&m_lookup_fail);
    uint64_t pool_hit = atomic_load(&m_pool_hit);
    uint64_t pool_miss = atomic_load(&m_pool_miss_connect);
    uint64_t destructor_drops = atomic_load(&m_destructor_pool_drops);
    uint64_t reloads = atomic_load(&m_reloads);

    /* Stable, machine-readable output for run.sh to scrape. */
    printf("RESULT mode=delme%d_realloc%d "
           "reloads=%llu lookup_ok=%llu lookup_fail=%llu "
           "lookup_fail_pct=%.2f "
           "pool_hits=%llu pool_misses=%llu "
           "pool_miss_pct=%.2f "
           "destructor_drops=%llu\n",
           BUG_DELME_FILTER, BUG_REALLOC_CLASSES,
           (unsigned long long)reloads,
           (unsigned long long)lookup_ok,
           (unsigned long long)lookup_fail,
           (lookup_ok + lookup_fail)
             ? 100.0 * lookup_fail / (double)(lookup_ok + lookup_fail) : 0.0,
           (unsigned long long)pool_hit,
           (unsigned long long)pool_miss,
           (pool_hit + pool_miss)
             ? 100.0 * pool_miss / (double)(pool_hit + pool_miss) : 0.0,
           (unsigned long long)destructor_drops);
    return 0;
}
